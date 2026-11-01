# NanoDet-Plus-m (416) -- person detector

Source: https://github.com/RangiLyu/nanodet, release `v1.0.0-alpha-1`,
asset `nanodet-plus-m_416_ncnn.zip`. Pre-converted to NCNN format by the
model's own author; used here unmodified.

License: Apache License 2.0, Copyright 2020-2021 RangiLyu.
Full text: https://github.com/RangiLyu/nanodet/blob/main/LICENSE

Chosen over Ultralytics YOLOv8 specifically for this permissive license
-- YOLOv8 is AGPL-3.0, which would obligate FPVR's own source to go AGPL
too once distributed to teammates. See
core/src/ai/nanodet_decoder.h for the decode implementation (also ported
from this same repo's demo_ncnn/nanodet.cpp, same Apache-2.0 license) and
the plan at /home/itsrebasetime/.claude/plans/i-want-to-add-transient-lemur.md
for the full reasoning.

Trained on COCO (80 classes); this project only decodes the "person"
class (index 0) -- see nanodet_decoder.h.
