// Adapted from NeoDizzy's tag bridge (GPL-3.0), limited to downloaded MP3/FLAC.
#import <Foundation/Foundation.h>
#include "AudioTagBridge.h"
#include <tfilestream.h>
#include <tpropertymap.h>
#include <tvariant.h>
#include <mpegfile.h>
#include <flacfile.h>
#include <memory>
#include <cstring>

using namespace TagLib;

static char *result(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
static char *failure(NSString *message) { return result(@{@"error": message}); }
static NSString *text(const String &value) { return [NSString stringWithUTF8String:value.toCString(true)] ?: @""; }
static String tag(NSString *value) { return String(value.UTF8String, String::UTF8); }
static NSArray *fields() {
    return @[@"TITLE", @"ARTIST", @"ALBUM", @"ALBUMARTIST", @"TRACKNUMBER", @"DISCNUMBER", @"LYRICS"];
}

static std::unique_ptr<TagLib::File> openFile(FileStream &stream, const char *path) {
    NSString *ext = [[NSString stringWithUTF8String:path].pathExtension lowercaseString];
    if([ext isEqualToString:@"flac"]) return std::make_unique<FLAC::File>(&stream);
    if([ext isEqualToString:@"mp3"]) return std::make_unique<MPEG::File>(&stream);
    return nullptr;
}
static bool valid(const std::unique_ptr<TagLib::File> &file) {
    return file && file->isValid() && file->audioProperties() && file->audioProperties()->lengthInMilliseconds() > 0;
}
static int frontCover(const List<VariantMap> &pictures) {
    int index = 0;
    for(const auto &picture : pictures) {
        if(picture.contains("pictureType") && picture["pictureType"].toString() == "Front Cover") return index;
        ++index;
    }
    return pictures.isEmpty() ? -1 : 0;
}

extern "C" char *NMTagRead(const char *path) {
    @autoreleasepool { try {
        FileStream stream(path, true);
        auto file = openFile(stream, path);
        if(!valid(file)) return failure(@"音频文件损坏或格式不受支持。");
        auto properties = file->properties();
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for(NSString *key in fields()) {
            NSMutableArray *strings = [NSMutableArray array];
            for(const auto &value : properties[tag(key)]) [strings addObject:text(value)];
            values[key] = strings;
        }
        auto pictures = file->complexProperties("PICTURE");
        int index = frontCover(pictures);
        NSString *cover = @"";
        if(index >= 0) {
            auto bytes = pictures[index]["data"].toByteVector();
            if(bytes.size() <= 20 * 1024 * 1024) {
                cover = [[NSData dataWithBytes:bytes.data() length:bytes.size()] base64EncodedStringWithOptions:0];
            }
        }
        return result(@{@"values": values, @"cover": cover});
    } catch(...) { return failure(@"读取音频标签失败。"); } }
}

extern "C" char *NMTagWrite(const char *path, const char *json) {
    @autoreleasepool { try {
        FileStream stream(path);
        auto file = openFile(stream, path);
        if(!valid(file) || stream.readOnly()) return failure(@"此音频不可写或文件已损坏。");
        NSDictionary *input = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:nil];
        NSDictionary *values = input[@"values"];
        if(![values isKindOfClass:NSDictionary.class]) return failure(@"音频标签数据无效。");
        auto properties = file->properties();
        for(NSString *key in fields()) {
            NSArray *array = values[key];
            if(!array) continue;
            properties.erase(tag(key));
            StringList strings;
            for(NSString *value in array) strings.append(tag(value));
            if(!strings.isEmpty()) properties.insert(tag(key), strings);
        }
        auto rejected = file->setProperties(properties);
        for(NSString *key in fields()) {
            if(values[key] && rejected.contains(tag(key))) return failure(@"此格式无法保存所需音频标签。");
        }
        if(NSString *encoded = input[@"cover"]) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
            if(!data.length || data.length > 20 * 1024 * 1024) return failure(@"封面数据无效。");
            auto pictures = file->complexProperties("PICTURE");
            int replaced = frontCover(pictures), index = 0;
            List<VariantMap> updated;
            VariantMap picture;
            picture.insert("data", ByteVector((const char *)data.bytes, (unsigned int)data.length));
            picture.insert("mimeType", tag(input[@"mime"] ?: @"image/jpeg"));
            picture.insert("pictureType", String("Front Cover"));
            picture.insert("description", String(""));
            updated.append(picture);
            for(const auto &existing : pictures) if(index++ != replaced) updated.append(existing);
            if(!file->setComplexProperties("PICTURE", updated)) return failure(@"此音频无法保存封面。");
        }
        if(!file->save()) return failure(@"保存标签失败，请检查文件权限和剩余空间。");
        return result(@{@"ok": @YES});
    } catch(...) { return failure(@"写入音频标签失败。"); } }
}

extern "C" void NMTagFree(char *value) { free(value); }
