# boil-water
zynq7020作为主控板，PT1000结合MAX31865测量温度，PID结合半岛制冷片进行温度控制

## 完成第一次push

成员第一次 push，可以按下面流程操作：**下载仓库 → 创建自己的分支 → 修改并提交 → 登录 GitHub 并推送。**

以下命令都在**成员自己的电脑**上执行。先确保成员已经接受你的 Collaborator 邀请。

### 1. 第一次下载仓库

在终端进入准备存放项目的目录，再执行：

```bash
git clone https://github.com/lee-2357/boil-water.git
cd boil-water
```

如果已经成功下载过，就直接进入已有仓库文件夹，不用重复 clone。

### 2. 配置提交身份

把下面的名字和邮箱换成成员自己的信息：

```bash
git config user.name "成员自己的名字"
git config user.email "成员自己的GitHub邮箱"
```

这里仅对当前仓库生效。**提交身份不等于 GitHub 登录认证。**

### 3. 从最新 main 创建自己的分支

```bash
git switch main
git pull --ff-only origin main
git switch -c feature/temperature-sensor
```

`feature/temperature-sensor` 是示例名字，可以换成成员负责的功能名。

### 4. 修改文件并提交

例如先修改、保存 `README.md`，补充自己负责的模块说明，然后执行：

```bash
git status
git diff
git add README.md
git commit -m "补充温度采集模块说明"
```

如果修改的是其他文件，把 `README.md` 换成对应路径。必须实际修改并保存文件，才能产生新的提交。

### 5. 第一次 push

```bash
git push -u origin feature/temperature-sensor
```

这会把自己的分支上传到你的仓库，**此时 main 还不会改变**。

使用 HTTPS 时，认证方式取决于成员电脑上的配置：

- **出现浏览器登录页面**：登录被邀请的 GitHub 账号，完成授权。
- **终端要求 Username 和 Password**：用户名填自己的 GitHub 用户名，密码位置填自己的 **PAT（个人访问令牌）**，不能填 GitHub 登录密码。

如果使用细粒度 PAT，应选择你的仓库，授予 **Contents: Read and write** 权限。令牌在成员自己的 GitHub **Settings → Developer settings → Personal access tokens** 中创建，不要分享或写进代码。

**HTTPS 推送不一定需要 SSH 密钥。** 如果安装 Git 时配置了 Git Credential Manager，通常可以通过浏览器完成登录。

### 6. 确认成功并发起 PR

终端出现类似下面的信息，就表示上传成功：

```text
[new branch] feature/temperature-sensor -> feature/temperature-sensor
```

成员随后进入 GitHub 仓库，点击 **Compare & pull request**，确认：

```text
base: main
compare: feature/temperature-sensor
```

创建 PR 后，你检查修改并点击 **Merge pull request**，代码才会进入 `main`。

以后成员在同一分支继续提交，只需要：

```bash
git add 修改的文件路径
git commit -m "本次修改说明"
git push
```

如果第一次 push 报 `403` 或 `Permission denied`，先检查：**邀请是否已接受、认证账号是否正确、令牌是否有这个仓库的写权限。**

*注：如果发现无法正常push或PR的话，可能是权限问题，需要和2357联系*

## 日常开发流程
流程图如下：
更新 main → 创建功能分支 → 修改、commit → push
                                         ↓
                                  创建 PR、审核、合并
                                         ↓
                              更新 main，开始下一个任务

你们可以统一使用这套流程：**获取最新 main → 在自己的分支开发 → 提交并 push → 自己创建 PR → 审核后合并。**

下面以成员负责温度采集功能为例。

### 1. 第一次下载仓库（只做一次）

```bash
git clone https://github.com/lee-2357/boil-water.git
cd boil-water
```

已经下载过的成员，直接进入本地仓库文件夹即可。

### 2. 每次开始一个新任务

先确保之前的修改已经提交或暂存，再执行：

```bash
# 切换到 main
git switch main

# 更新本地 main
git pull --ff-only origin main

# 从最新 main 创建自己的功能分支
git switch -c feature/temperature-sensor
```

新分支已经包含当前 `main` 的全部代码。每个新任务使用一个新的分支名，例如 `feature/pid-control` 或 `fix/sensor-reading`。

### 3. 在自己的分支修改代码并提交

修改、保存文件后：

```bash
# 检查修改
git status
git diff

# 添加需要提交的文件，替换为实际路径
git add README.md

# 保存为一次提交
git commit -m "补充温度采集模块说明"
```

可以多次修改、多次 commit。提交前检查文件列表，避免把 Vivado 的临时文件、构建结果一起上传。

### 4. 开发期间，获取 main 的新代码

如果其他成员已经把代码合入 `main`，先提交自己的修改，然后在**自己的功能分支上**执行：

```bash
git fetch origin
git merge origin/main
```

这会把最新 `main` 合入当前功能分支，保留自己的开发内容。

如果出现冲突，编辑冲突文件、确认最终内容后执行：

```bash
git add 已解决的文件路径
git commit
```

合并后重新检查代码、运行相关测试。

### 5. push 自己的分支

第一次上传该分支：

```bash
git push -u origin feature/temperature-sensor
```

之后同一分支继续修改，执行 commit 后只需要：

```bash
git push
```

**这些操作更新的是自己的远程分支，main 此时不会改变。** 推送时使用成员自己的 GitHub 账号完成认证。

### 6. 自己在 GitHub 创建 PR

进入仓库网页：

1. 点击 **Pull requests → New pull request**。
2. 选择 **base: main**。
3. 选择 **compare: feature/temperature-sensor**。
4. 检查改动，填写本次功能和测试情况。
5. 点击 **Create pull request**，需要的话指定审核人。

**成员可以自己创建 PR，不需要你代操作。** 如果 PR 创建后需要修改，继续在原分支 commit、push，PR 就会自动更新，不用重新创建。

审核、检查通过后，有权限的人点击 **Merge pull request**。PR 作者不能批准自己的 PR；是否能自己点击合并，取决于仓库规则。

### 7. PR 合并后，准备下一个任务

```bash
git switch main
git pull --ff-only origin main

# 为下一个任务创建新分支
git switch -c feature/pid-control
```

建议合并后的旧功能分支就结束使用，下一个任务从更新后的 `main` 创建新分支。

日常流程可以记成：

```text
更新 main → 创建功能分支 → 修改、commit → push
                                         ↓
                                  创建 PR、审核、合并
                                         ↓
                              更新 main，开始下一个任务
```

## 当前进度于任务安排

任务流程图:
```text
进程1:
读取ads1263的数据 -> 进行直流误差分析并修正误差 -> 读取PT1000+MAX31865并计算温度 -> 与高精度温度计进行对比，进行二次修正
进程2:
拿取u型端子线，组装开关电源和烧开水系统（不包括加热棒和继电器）-> 先写出一版本可以用的烧开水代码（可以优先使用MAX31865自兼容的12bitadc，先读取数据并进行测试），测试代码完整性 
进程3:(在完成进程1和2以后)
结合ads1263计算出来的温度值、稳定温度值、和实际温度值，进行误差修正以及调整参数。

```

### 模块资料
#### ads1263 32bit 低采样率adc


```text
模块相关信息：
量程0-5v
供电电压3.3-5v
大致静态电流浮动范围10uV
```

购买并调试ads1263(链接：https://item.taobao.com/item.htm?id=629282869603&mi_id=0000p6myBvXNMH_kTdBE8oJaVZx_Re9u93pvVMzGqauJtmo&spm=tbpc.boughtlist.suborder_itemtitle.1.7dd72e8dbf5TaL)


#### 热电阻模块
模块连接：
https://item.taobao.com/item.htm?from=detail&id=744886636009&mi_id=0000ywOaWYKgBqGtzwDLi1W3PdRosqKG2PAOYWD5A59qCng&spm=tbpc.orderdetail.suborder_itempic.1.10876aa6kNTjur

热电阻模块资料如下：

热电阻温度传感器模块_LZ_TD200(210)_V1.0模块资料链接：https://pan.baidu.com/s/15drTm-yj2n5QpWswvl6-NA 
提取码：jyvc

##### 文件夹树

```text
热电阻PT100&PT1000温度传感器模块资料/
├── 热电阻温度传感器模块_LZ_TD200(210)_V1.0模块资料/
│   ├── 上位机软件/
│   │   └── 凌智-热电阻检测测试.exe
│   ├── 串口协议说明/
│   │   └── 模块协议说明文档.pdf
│   ├── 尺寸图/
│   │   ├── 【3D尺寸图】热电阻温度传感器模块_LZ_TD200(210)_V1.0.png
│   │   ├── 【DXF】热电阻温度传感器模块_LZ_TD200(210)_V1.0.dxf
│   │   └── 【尺寸图】热电阻温度传感器模块_LZ_TD200(210)_V1.0.png
│   ├── 用户手册/
│   │   └── 【用户使用手册】热电阻温度传感器模块_LZ_TD200(210)_V1.0用户使用手册.pdf
│   ├── 芯片手册/
│   │   ├── STC8H8K64U.PDF
│   │   ├── TI-INA826.pdf
│   │   ├── TI-LMV358.pdf
│   │   └── TI-REF3025.pdf
│   └── COM15_3.csv
└── 热电阻温度传感器模块_LZ_TD200(210)_V1.0模块资料.rar
```


主要资料内容：
- 用户手册，写明如何根据模拟输出AO计算出电阻，进而计算出当前温度；
- 模块协议说明文档.pdf，写明uart串口发送的数据格式是什么，如何解析读取数据（在使用模块自带的12bitadc的读取数据的时候需要用到）

