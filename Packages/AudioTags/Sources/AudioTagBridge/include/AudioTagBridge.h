#ifndef NM_AUDIO_TAG_BRIDGE_H
#define NM_AUDIO_TAG_BRIDGE_H
#ifdef __cplusplus
extern "C" {
#endif
// UTF-8 JSON result. The caller releases returned storage with NMTagFree.
char *NMTagRead(const char *path);
char *NMTagWrite(const char *path, const char *json);
void NMTagFree(char *value);
#ifdef __cplusplus
}
#endif
#endif
