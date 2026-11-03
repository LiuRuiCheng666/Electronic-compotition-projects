# 一帧入画——智能视频绘画系统

团队：全都队　团队编号：41983

基于易灵思 Ti60F225I3 FPGA 与 Sapphire RISC-V，实现摄像头 / HDMI 采集、自适应曝光与白平衡、轻量 NN 风格化、DDR 多帧缓冲、高清对照显示和网口照片创作。五种风格共用硬件计算核心，网页提供上传、风格选择、原图比较与作品下载。

## 工程目录

|目录|内容|
|---|---|
|01_FPGA|Efinity 工程、完整 RTL/IP、RISC-V SDK及C源码、ROM初始化、当前模型、必要构建支持|
|02_网页应用|Python 服务、原始传输协议、HTML/CSS/JS、依赖和许可证、离线测试|
|03_网口工具|命令行图片/视频逐帧传输工具源码和测试；Python依赖通过requirements安装|
|04_烧录文件|最终五风格完整Flash镜像，以及配置文件|
|05_技术资料|资源/时序摘要和使用说明|

## 烧录与运行

完整启动使用 `04_烧录文件/OSD_SIMPLE_SELECTED5_FULL_FLASH.hex`，Programmer 选择 **SPI Active using JTAG Bridge**，起始地址 `0x00000000`，解码长度 **4214816 字节**。镜像已包含 FPGA 配置与五套模型，模型区起始 `0x00400000`。写入校验后断电重新上电。`CONFIG_ONLY` 文件用于单独配置，不能替代含权重的完整启动镜像。

板端默认网络 `192.168.0.2:40000`，电脑有线网卡设置同网段地址，例如 `192.168.0.3/24`；USB串口使用115200波特率，端口号在网页按实际设备选择。启动前安装 `02_网页应用/requirements.txt` 所列依赖，再双击根目录 `启动一帧入画.cmd`，访问 `http://127.0.0.1:8770/`。可通过环境变量 `YIZHEN_PYTHON` 指定 Python 路径。推荐 Windows、Python 3.10；应用附该平台的 Pillow 和纯 Python 串口依赖，其他环境通过 pip 安装。

五种风格依次为：0 复古建筑版画（诺贝尔）、1 工程线稿、2 浮雕、3 首版细像素、4 故障艺术。处理尺寸1280×720，NN核心160MHz，DDR400MHz，输出有效区域1920×1080。

## 阅读与重新构建

使用 **Efinity 2026.1.132** 打开 `01_FPGA/ti60f225_oob.xml`，顶层为 `ti60f225_oob_top`，器件Ti60F225 / I3。项目内部原有文件名保持不变，避免破坏IP、初始化文件和源码引用。

嵌入式C源码位于 `01_FPGA/embedded_sw/soc/software/standalone/uart/nnObserverDemo/src/`。配置 `RISCV_PREFIX` 为RISC-V编译器前缀后，在01_FPGA中运行 `python tools/build_light_merge_firmware.py --install` 更新固件与四路ROM初始化。

`python tools/rebuild.py --stage plan --efinity-home <Efinity安装目录>` 检查本地化构建命令。`--stage all` 依次执行综合、映射端点约束绑定和布局布线；`--stage pgm` 生成配置，再用 `tools/build_flash_image.py` 合并当前权重。每轮新构建以实际时序结果为准。已提供最终烧录文件可直接用于部署，整理过程不重新配置开发板。

`python 02_网页应用/run_checks.py` 运行本地离线测试。`python verify_submission.py` 检查交付文件哈希和完整Flash模型区。离线测试只验证应用和协议，不替代实板推理。

## 文件整理说明

保留最终工程所需的源码、IP、SDK、模型、ROM初始化与烧录文件；移除了历史候选工程、重复归档、布局布线中间大文件、应用运行数据和无关验收截图。命令行工具的OpenCV/NumPy安装副本不重复打包，源码与依赖清单保留。第三方IP、库与随附许可证保持其原有权利声明，本项目不为第三方代码重新授予许可证。
