# 当前玻璃风格：匹配标准网络对比

本轮只做推理，没有训练。当前提交slot2与原QAT检查点重新导出的4096B逐字节相同。
20张保留集图片与此学生模型训练/验证列表无SHA交集；大模型早期预训练接触情况未知。

|比较|平均PSNR dB|平均RGB SSIM|
|---|---|---|
|integer_vs_matched_teacher|16.9134|0.557636|
|integer_vs_matched_qat_pytorch|∞（全部逐像素相同）|1.000000|
|integer_vs_official_mosaic|13.8941|0.348250|

|GPU网络|参数数|中位延迟ms|P95 ms|
|---|---|---|---|
|student_qat_pytorch|1551|10.6584|12.8877|
|matched_standard_teacher|1679235|25.4351|25.7561|
|official_mosaic|1679235|26.2643|26.4854|

设备：NVIDIA GeForce RTX 5060 Laptop GPU
Same CUDA device, inference-only, one640x480 image, five warmups, thirty CUDA-event timings. Excludes file IO; student display tone not timed. Not FPGA board latency.

限制：
- Matched teacher comparison for current final slot2 (emboss/glass); other four styles are outside this same-style comparison
- Original official Mosaic weights are initialization, not the same fine-tuned teacher; scores are not an aesthetic ranking
- Physical board throughput/switch/task measurements are collected separately in camera_result_2; this script measures software quality and GPU timings
- Source training was earlier; this script only infers existing weights; original pretraining exposure is unknown
