# Module: Links — GNU longname/longlink payload handling (pure).
#
# GNU L/K entries carry the real name/link bytes as the data payload;
# the payload is NUL-trimmed and used for the next entry.

import Base
import ./bytes.bend as B

def payload(b: B.Bytes) -> List<&2, U32>:
  B.cstr(B.to_list(b))
