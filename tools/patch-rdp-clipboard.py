"""Bound the only enabled static channel before fragment allocation/queueing."""
from pathlib import Path
root=Path(__file__).resolve().parent.parent/'build/rdp-deps/src/FreeRDP-3.33.0'
p=root/'channels/client/addin.c'
s=p.read_text();marker='/* MacTerm bounded clipboard channel */'
patch='''\n\t/* MacTerm bounded clipboard channel */
\tif (internals && internals->channel_name && strcmp(internals->channel_name, "cliprdr") == 0 &&
\t    (totalLength > 2162688U || dataLength > totalLength ||
\t     (internals->queue && MessageQueue_Size(internals->queue) >= 16)))
\t\treturn ERROR_INVALID_DATA;
'''
needle='\tmsg_proc_internals* internals = MsgsHandle;\n\twStream* data_in = nullptr;'
assert s.count(needle)==1
if marker not in s:s=s.replace(needle,needle+patch);p.write_text(s)
else:assert patch in s,'Unexpected channel patch; inspect before rebuilding'
print('Verified bounded cliprdr fragment/queue patch')
