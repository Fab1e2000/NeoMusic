#ifndef NM_AUDIO_TAG_BRIDGE_H
#define NM_AUDIO_TAG_BRIDGE_H
#ifdef __cplusplus
extern "C" {
#endif
char *NMTagRead(const char *path);
char *NMTagWrite(const char *path, const char *json);
void NMTagFree(char *value);
#ifdef __cplusplus
}
#endif
#endif
