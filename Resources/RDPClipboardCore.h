#ifndef MACTERM_RDP_CLIPBOARD_CORE_H
#define MACTERM_RDP_CLIPBOARD_CORE_H
#include <freerdp/client/cliprdr.h>
#include <cjson/cJSON.h>
#include <pthread.h>
#define MT_CLIP_UTF8_MAX 1048576U
#define MT_CLIP_WIRE_MAX (2U*MT_CLIP_UTF8_MAX+2U)
typedef struct {
 pthread_mutex_t lock;CliprdrClientContext* channel;void* opaque;void (*emit)(void*,cJSON*);
 BOOL ready,remoteText,readOnly,readBlocked,offerBlocked,offerStale;UINT32 caps;
 UINT32 readID,offerID;UINT64 revision,readRevision,readDeadline,offerDeadline;
 BYTE* offered;size_t offeredLength;
} MTClipboard;
void mt_clip_init(MTClipboard* clip,void* opaque,void (*emit)(void*,cJSON*),BOOL readOnly);
void mt_clip_attach(MTClipboard* clip,CliprdrClientContext* channel);
void mt_clip_detach(MTClipboard* clip);
void mt_clip_destroy(MTClipboard* clip);
void mt_clip_read(MTClipboard* clip,UINT32 id);
void mt_clip_offer(MTClipboard* clip,UINT32 id,const char* encoded);
void mt_clip_tick(MTClipboard* clip);
BOOL mt_clip_validate(const BYTE* data,size_t length,size_t* meaningful);
#endif
