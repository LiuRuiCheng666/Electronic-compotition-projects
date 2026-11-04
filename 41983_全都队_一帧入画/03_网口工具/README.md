# 网口图片与视频帧工具

该目录与`01_FPGA/host`中的主机工具保持同一版本，使用最终五槽协议：0复古建筑版画、1工程线稿、2浮雕、3首版细像素、4故障艺术。图片风格化在FPGA执行，电脑负责文件准备、传输与结果保存。

在本目录执行`python -m pip install -r requirements.txt`安装OpenCV、NumPy和Pillow。网络设置与启动条件见项目根目录README。

```powershell
python host/a_image_transfer.py E:/images/input.jpg E:/images/result.png --ip 192.168.0.2 --bind-ip 192.168.0.3 --style 4
python host/a_image_batch.py E:/images/input.jpg --out E:/results/five_styles --styles 0 1 2 3 4
python host/a_video_transfer.py E:/videos/input.mp4 --out E:/results/video --style 4 --max-frames 4
```

输出目录按参数要求选择新目录。视频工具逐帧提交板端图片任务，可生成本地对照图、1fps故事板和MJPEG预览；网口视频采样速率与摄像头/HDMI实时30fps推理分别计量。

中文路径中的帧图通过Python读取字节后交由OpenCV解码，避免Windows下`imread`无法打开中文路径。输入/输出视频、槽4任务及预览的本地夹具测试均有覆盖，测试不会连接开发板。

批量图片默认遍历全部五槽。压力测试写入`model_count=5`并循环五种风格；日志分析器按记录中的模型数量检查顺序，同时兼容未声明模型数的四槽记录。最终交付文件一致性由根目录`verify_submission.py`检查。
