"""Compatibility shims loaded before SGLang starts."""

try:
    from sglang.srt.managers.schedule_batch import Modality
    from sglang.srt.multimodal.processors.base_processor import BaseMultimodalProcessor
    from sglang.srt.multimodal.processors.transformers_auto import (
        TransformersAutoMultimodalProcessor,
    )
    from sglang.srt.utils import load_image

    if not hasattr(Modality, "MULTI_IMAGES"):
        Modality.MULTI_IMAGES = Modality.IMAGE

    _base_mm_processor_init = BaseMultimodalProcessor.__init__

    def _llava_onevision2_compat_init(self, *args, **kwargs):
        _base_mm_processor_init(self, *args, **kwargs)
        self.ATTR_NAME_TO_MODALITY.setdefault("patch_positions", Modality.IMAGE)

    if not getattr(BaseMultimodalProcessor.__init__, "_llava_onevision2_compat", False):
        _llava_onevision2_compat_init._llava_onevision2_compat = True
        BaseMultimodalProcessor.__init__ = _llava_onevision2_compat_init

    def _load_pil_images(self, image_data):
        if not image_data:
            return []
        images = []
        for data in image_data:
            img, _ = load_image(data, gpu_image_decode=False)
            if img.mode != "RGB":
                img = img.convert("RGB")
            images.append(img)
        return images

    if not getattr(
        TransformersAutoMultimodalProcessor._load_images,
        "_llava_onevision2_compat",
        False,
    ):
        _load_pil_images._llava_onevision2_compat = True
        TransformersAutoMultimodalProcessor._load_images = _load_pil_images
except Exception:
    # Keep startup behavior unchanged if SGLang changes this import path later.
    pass
