# Ego 模型约定（中文版）

本文是模拟器中 Ego（己方机器人）模型的**规范性约定**。任何符合本约定的机器人，
只需新增一个 profile 文件即可接入，**不需要改 GDScript**。英文原文见
[`EGO_MODEL_CONTRACT.md`](EGO_MODEL_CONTRACT.md)，两者内容不一致时以英文版为准。

实现位置：

- `scripts/sim/EgoRig.gd` —— 唯一的、配置驱动的 rig 构建器。
- `scripts/sim/EgoModelConfig.gd` —— profile 读取、默认值与校验。
- `config/ego/*.yaml` —— 每个机器人一个 profile（仓库自带 `vehicle`、
  `infantry_light`、`debug`、`sentry24`、`sentry24_urdf`、`urdf_gimbal`、
  `sdf_gimbal`）。
- `scripts/scenario/ScenarioSchema.gd` —— 把实际发现的 profile id 作为
  `ego.model` 的合法取值。

## 1. 坐标系与单位

| 项目 | 要求 |
| --- | --- |
| 引擎 | Godot 4.7 Forward+；资源为 Godot 导入的场景（`.glb`/`.gltf`/`.scn`/`.tscn`）**或** URDF/SDF 机器人描述（`.urdf`/`.xacro`/`.sdf`，Phase 5，见 §9） |
| 单位 | 米 |
| 上方向 | `+Y` |
| yaw = 0 时的前方向 | `−Z` |
| 右方向 | `+X` |
| 原点 | 地面上的底盘中心（`asset.floor_offset_m` 之后 `y = 0`） |
| 底盘 yaw | 绕世界 `Y` 轴旋转；正方向 = 左转 |

rig 的节点链为 `EgoRoot（底盘 yaw）→ GimbalYaw → GimbalPitch → CameraMount`。
`EgoRig.set_gimbal(yaw_deg, pitch_deg)` 是云台控制的唯一入口；世界位姿由
`EgoController` 负责。

## 2. 必需的节点结构

```
<Ego 模型根节点>
├─ BASE / CHASSIS / ...              # 底盘网格（名称随意）
└─ GIMBAL                            # 枢轴节点，按名字查找（profile `gimbal.pitch_node`）
   ├─ GIMBAL_MAIN / BARREL / ...     # 云台头部网格（名称随意）
   ├─ CAM_DIRECTION                  # 相机眼睛位置，空 Node3D
   └─ SHOT_DIRECTION                 # 可选瞄准标记，空 Node3D
```

双轴云台（yaw 与 pitch 轴分开）会多一个节点：

```
<Ego 模型根节点>
├─ BASE / CHASSIS / ...
└─ GIMBAL_YAW                        # yaw 枢轴，profile `gimbal.yaw_node`
   ├─ YAW_BASE / HOPPER / ...        # 仅随 yaw 运动的网格（名称随意）
   └─ GIMBAL                         # pitch 枢轴，profile `gimbal.pitch_node`
      ├─ GIMBAL_MAIN / BARREL / ...  # 随 pitch 运动的头部网格（名称随意）
      ├─ CAM_DIRECTION
      └─ SHOT_DIRECTION
```

- `GIMBAL_YAW`（名字由 `gimbal.yaw_node` 指定，可选）：当它存在且是 `GIMBAL`
  的祖先时，它的平移就是 **yaw 枢轴**（绕世界 `Y` 轴），`GIMBAL` 保留相对它的
  建模偏移，于是 yaw 与 pitch 各自绕真实的轴旋转。没有它时两个关节共用
  `GIMBAL` 的平移（单轴模型，例如 `vehicle.glb`）。
- `GIMBAL`（名字由 `gimbal.pitch_node` 指定）：该节点会挂到显式 yaw 枢轴下，被
  复位为单位变换（`position = 0`、`rotation = 0`）并作为 pitch 关节。它建模时的
  平移会被保留为枢轴位置（`EgoRig._build_gimbal_from_model`）。
- `CAM_DIRECTION`（名字由 `camera.marker_node` 指定）：空节点，其**在云台空间中的
  平移**就是相机眼睛位置。默认 `gimbal` 相机安装方式只用平移；只有
  `cam_direction` 相机预设才需要它的旋转，此时按 CAD 相机坐标系解释：
  视线方向 = 本地 `−Y`，上方向 = 本地 `−Z`，再经 `−90°` X 修正得到 Godot 相机位姿。
- `SHOT_DIRECTION`：可选的瞄准 / 炮口标记，默认相机不使用。
- 相机标记与 `SHOT_DIRECTION` 是唯一不参与安装俯仰补偿、直接留在 pitch 关节上的
  节点；其余子节点都会被移到 `GimbalVisual` 下并绕关节原点施加
  `gimbal.install_pitch_deg`。这份「不补偿」名单由 `camera.marker_node` +
  `SHOT_DIRECTION` **推导**，不是 profile 字段。

网格只用于视觉：rig 不需要碰撞体、物理体、骨骼、动画、LOD 或 UV。构建完成后所有
`GeometryInstance3D.layers` 被强制为 `2`（Ego 层）；feed 相机剔除 layer `1`，因此
除非操作员开启自身入镜（`F2`），否则 Ego 不会出现在发布的图像里。

## 3. 姿态与尺寸规则

- `asset.unit_scale`：乘到加载资源的根节点上（GLB 场景或描述型网格）。以毫米
  建模的模型用 `0.001`（例如 `infantry.glb`）；米制模型用 `1.0`（默认）。
- `asset.floor_offset_m`：把资源根节点整体抬升，使底盘底部落在 `y = 0`。
  `vehicle.glb` 的底盘底部在 `y = −0.2101`，所以 profile 用 `0.2101`。
- `gimbal.install_pitch_deg`：抵消视觉头部建模时带进来的安装俯仰
  （`vehicle.glb` 头部建模上仰 25° → 写 `−25`）。新模型应建模成水平，此值保持 `0`。
- `gimbal.visual_offset_m`：补偿视觉枢轴的平移（默认 `[0, 0, 0]`，只有当水平化后的
  头部会穿进底盘时才需要）。
- `asset.hide_node_prefixes`：名字以这些前缀开头的导入节点在加载时隐藏（例如未装配
  的 `激光检测总装`）。源 GLB 不会被修改。
- 模型尺寸应与步兵大致相当（占地约 0.5 m）；不要让可见几何漂浮在云台上方。

## 4. Profile 文件（schema version 2）

每个机器人一个 YAML 文件，放在 `config/ego/` 下，文件名 `<id>.yaml`。`id` 必须
唯一；`scenario.ego.model` 与 `EgoRig.preset` 都用它。

```yaml
schema_version: 2                  # 必需，必须为 2
id: vehicle                        # 必需，唯一
display_name: Vehicle (full CAD)   # UI / 诊断显示名

asset:                             # 必需：唯一的模型来源
  path: res://assets/robots/vehicle/vehicle.glb   # 必需；扩展名决定加载器
  unit_scale: 1.0                  # 毫米模型写 0.001
  floor_offset_m: 0.2101           # 底盘底部 -> y = 0
  hide_node_prefixes:              # 加载后隐藏的节点前缀
    - "激光检测总装"
  mesh_root: ""                    # 仅 urdf/sdf：网格重映射根目录

gimbal:
  # 场景型资源（.glb / .gltf / .scn / .tscn）：
  pitch_node: GIMBAL               # pitch 枢轴；纯底盘模型可省略
  yaw_node: ""                     # 可选的独立 yaw 枢轴（双轴云台）
  install_pitch_deg: -25.0         # 安装俯仰补偿
  visual_offset_m: [0.0, 0.0, 0.0]
  synthetic: {}                    # 可选，见 §5
  # 描述型资源（.urdf / .xacro / .sdf）：
  yaw_joint: gimbal_yaw_joint      # 由操作员 yaw 驱动的转动关节
  pitch_joint: gimbal_pitch_joint  # 由操作员 pitch 驱动的转动关节

camera:
  # 场景型资源：
  marker_node: CAM_DIRECTION       # 眼睛位置空节点
  # 所有资源（marker / 描述相机帧缺失时的回退位置）：
  mount_m: [-0.002017, 0.1963421255, -0.0600251630]
  # 描述型资源：
  link: camera_link
  optical_frame: camera_optical_frame
```

### 4.1 资源类型由扩展名推断，不需要声明

`asset.path` 的扩展名决定用哪个加载器，也决定 `gimbal` / `camera` 里哪些键合法：

| 扩展名 | 类型 | 加载器 |
| --- | --- | --- |
| `.glb`、`.gltf`、`.scn`、`.tscn` | `scene` | `load()` 成 `PackedScene` |
| `.urdf`、`.xacro` | `description`（format `urdf`） | `UrdfLoader` |
| `.sdf` | `description`（format `sdf`） | `SdfLoader` |
| 其他 | 报错 | — |

- 只有一个 `asset.path`，因此**不可能**把两种来源混在同一个 profile 里。
- 属于另一种来源的键会报**错误**（例如
  `gimbal.yaw_joint is not valid for scene assets`）；不认识的键只给警告。
- 描述型 profile 必须写 `gimbal.yaw_joint` 与 `gimbal.pitch_joint`；场景型 profile
  必须提供 `gimbal.pitch_node` 或 `gimbal.synthetic`。
- 归一化后的字典额外带 `source`（`"scene"` / `"description"`），且只包含该来源适用
  的块与键。

所有可选键的默认值集中在 `EgoModelConfig`（`ASSET_DEFAULTS`、
`SCENE_GIMBAL_DEFAULTS`、`DESCRIPTION_GIMBAL_DEFAULTS` 等）；必需值非法会报错，
rig 会退回内置的方块 fallback。

> 已知解析限制：仓库内置的 `YAMLParser` 会把**单元素流式数组**
> （`key: ["x"]`）读成空数组。单元素列表请用块状写法：
>
> ```yaml
> hide_node_prefixes:
>   - "激光检测总装"
> ```

## 5. 合成云台（纯底盘模型）

没有 pitch 枢轴节点的模型可以声明 `gimbal.synthetic`，rig 会根据 profile 构建枢轴链
和固定相机安装位置：

```yaml
gimbal:
  synthetic:
    yaw_pivot_m: [0.0, 0.152, 0.0]    # rig 空间（地面以上）的关节位置
    pitch_pivot_m: [0.0, 0.045, 0.0]
    parts:
      - name: PITCH_BODY
        attach: pitch        # model | yaw | pitch
        shape: box           # box | cylinder
        size: [0.16, 0.075, 0.13]
        position: [0.0, 0.02, -0.02]
        rotation_deg: [0.0, 0.0, 0.0]
        color: [0.06, 0.07, 0.08]       # RGB 或 RGBA

camera:
  mount_m: [0.0, 0.035, -0.11]        # 固定的相机位置（云台空间）
```

圆柱部件额外使用 `radius` 与 `height`。`attach: model` 的部件挂在已加载的底盘上，
而不是云台关节上。使用合成云台时相机安装位置固定为 `camera.mount_m`，相机预设不会
移动它。

## 6. 相机安装

- 默认相机预设（`camera_mount_preset = "gimbal"`）：眼睛**位置**取自相机标记，
  朝向 = 云台前向，可用 `camera_yaw_offset_deg` 微调。QYG 标定测得光轴偏角为
  0.000°，因此**不采用**标记自带的 CAD 朝向（`vehicle.glb` 中为左偏 3.7°）。
- `"cam_direction"`：完全采用 CAD 标记位姿（左偏 3.7°），用于忠于模型的截图。
- `"qyg"` / `"model"`：实验性的标定安装方式（`SimConfig.QYG_CAMERA_*`、
  `EgoRig.camera_mount_offset/rpy`）。
- 没有相机标记（或描述型没有相机帧）时，眼睛位置回退到 `camera.mount_m`——它与
  合成云台使用的固定安装位置是同一个键。

得到的 `gimbal_link → camera_link` 变换就是 ROS 后端发布的变换，因此若要用 feed
做自瞄验证，眼睛位置 / 朝向必须与真实标定一致。

## 7. 新增机器人

### 7.1 GLB 模型（Phase 1 路线）

1. 按 §1–§2 导出或转换成 Godot 导入的 `.glb`。
2. 运行 `godot --headless --path . --import`。
3. 新建 `config/ego/<id>.yaml`（复制现有 profile 再改值）。
4. 在场景里用 `ego.model: <id>` 选择它，或在代码里设置
   `EgoRig.preset = "<id>"`。
5. 验证：`godot --headless --path . --script res://tests/ego_profiles_check.gd`
   （所有 profile 都必须能构建），以及针对模型本身的
   `godot --headless --path . --script res://tests/ego_model_check.gd`。

任何符合 §1–§2 的 `.glb` 都可以替换 Ego：唯一要改的就是 profile
（`asset.path` + `asset.unit_scale` / `floor_offset_m` + `gimbal` 枢轴名）。
`debug`、`infantry_light`、`sentry24`、`vehicle` 就是同一机制在不同精度下的示例。

### 7.2 URDF/SDF 模型（Phase 5 路线）

1. 编写或导出机器人描述（URDF、`.xacro` 子集或 SDF 1.7）。
2. 用 `tools/prepare_robot_model.py` 把 ROS 帧的网格转成 Godot 帧
   （见 `tools/README.md`）；本身已是 Godot 帧的 `.glb`/`.obj` 可以直接引用。
3. 新建 `config/ego/<id>.yaml`，让 `asset.path` 指向该描述（§9）；在 `gimbal`
   下命名 yaw/pitch 关节，在 `camera` 下命名相机帧。
4. 新建一个 `ego.model: <id>` 的场景并运行验证。
5. 验证：`godot --headless --path . --script res://tests/urdf_sdf_check.gd`
   （加载器 / rig）以及 `.../tests/phase5_ego_check.gd`（集成、相机 / TF）。

## 8. 失败行为

- profile 缺失 / 非法：`EgoModelConfig` 报错；库为空时 `ScenarioSchema` 会拒绝所有
  `ego.model`，模拟器退回内置的 Phase 1 世界。
- 未知 `ego.model`：场景校验报错（加载时退回默认值并记录错误）。
- 场景缺失或既没有 `gimbal.pitch_node` 也没有 `gimbal.synthetic`：`EgoRig` 记录
  错误并构建方块 fallback rig，模拟器仍可启动。
- 描述缺失 / 无法解析，或映射的 yaw/pitch 关节不存在：`EgoRig` 记录错误并构建
  fallback rig；解析器警告（不支持的 xacro 宏、无法解析的 `package://` 网格）只记录
  日志，不中断。
- profile 只解析一次并缓存；改完 YAML 需要重启（测试可调用
  `EgoModelConfig.reload()`）。

## 9. 描述型模型（URDF/SDF，Phase 5）

`asset.path` 以 `.urdf`、`.xacro` 或 `.sdf` 结尾的 profile，会用机器人描述而不是导入
的 GLB 场景来构建 Ego。

- **加载器**：`UrdfLoader.load_file(path)`（URDF，以及文档化的 `.xacro` 子集：
  `xacro:arg`、`xacro:property`、`$(arg)`、`${expr}` 运算含 `pi`/`radians()`/
  `degrees()`、相对 `xacro:include`；`xacro:macro` 会告警并被移除）与
  `SdfLoader.load_file(path)`（SDF 1.7 的 link/joint pose、`relative_to`、
  `degrees`、PBR 材质）产出相同的 `RobotDescription`。支持的几何：`box`、
  `cylinder`、`sphere`、`mesh`。支持的关节类型：`fixed`、`revolute`、
  `continuous`、`prismatic`、`floating`、`planar`（后两种在 rig 中静止）。
- **坐标帧**：URDF/SDF 的 body 帧（X 前、Y 左、Z 上，RPY = Rz·Ry·Rx）由加载器用
  `SimConfig` 辅助函数转成 Godot 帧；关节 origin/axis 与视觉 origin 都按已转换的值
  存储。网格文件必须**按 Godot 帧**提供（ROS 帧网格先用
  `tools/prepare_robot_model.py` 转换）；加载器不会再旋转网格。
- **Rig**：`RobotRig.build(description, options)` 为每个 link 和 joint 建一个
  `Node3D`。`options`：`unit_scale`、`layers`、`visuals`、`mesh_root`。
  `set_joint_value(name, value)` 按建模轴驱动 revolute/continuous（弧度）与
  prismatic（米）关节。
- **Ego 集成**：`EgoRig` 用 profile 的 `gimbal.yaw_joint` / `gimbal.pitch_joint`
  实现 `set_gimbal()`；轴方向符号会被归一化，保证操作员正 yaw = 左转、正 pitch =
  抬头。相机安装位置由 `camera.optical_frame` 推导（未指定光学帧时用
  `camera.link` + 标准光学 RPY），并由 `EgoRig.get_camera_link()` /
  `get_camera_optical_frame()` 交给 `RosBackend` 发布描述自身的静态相机 TF。
  描述型 Ego 会忽略 `camera_mount_preset`，因为描述才是唯一权威。
- **限制**：仅视觉 / 运动学（无碰撞、无惯量、无关节动力学；Phase 7），
  `floating`/`planar` 关节静止，`package://` / `model://` 网格 URI 会告警并跳过，
  SDF 的 `<include>`/传感器/插件/嵌套模型会告警并跳过，`.dae` 转换需要 Blender ≤ 4.x
  （Blender 5 移除了 COLLADA 导入器）。示例与命令见
  `docs/PHASE5_ACCEPTANCE.md`。
