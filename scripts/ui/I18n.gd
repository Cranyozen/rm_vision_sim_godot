class_name I18n
extends RefCounted

## Minimal runtime i18n for the operator UI (English + Simplified Chinese).
##
## The msgid is the English UI text, so English needs no table and a missing
## translation always falls back to readable English.  `install()` registers a
## zh_CN Translation with Godot's TranslationServer, after which every Control's
## built-in `tr()` resolves the same strings (and `I18n.t()` works from static
## or non-Node code).
##
## Adding a language later means adding one dictionary + one entry in
## SUPPORTED_LOCALES; no import step or generated resource is involved, which
## keeps headless checks deterministic.
##
## The selected locale is persisted in user://ui.cfg; on a fresh install it
## follows the OS locale (zh* -> zh_CN, everything else -> en).

const SUPPORTED_LOCALES: Array[String] = ["en", "zh_CN"]
const LOCALE_NAMES := {"en": "English", "zh_CN": "中文"}
const FALLBACK_LOCALE := "en"
const CONFIG_PATH := "user://ui.cfg"
const CONFIG_SECTION := "ui"
const CONFIG_KEY := "locale"

## English msgid -> Simplified Chinese.  Format placeholders must stay
## identical to the English msgid (tests/i18n_check.gd verifies this).
const ZH_CN := {
	# --- HUD: status panel -------------------------------------------------
	"RM VISION SIM · PHASE 3": "RM VISION SIM · 阶段 3",
	"Scenario: %s   Field: %s": "场景: %s   场地: %s",
	"Ego: %s   View: %s": "Ego: %s   视角: %s",
	"FPS %5.1f   frame %5.2f ms": "FPS %5.1f   帧 %5.2f ms",
	"Gimbal  yaw %+6.1f°   pitch %+6.1f°": "云台  偏航 %+6.1f°   俯仰 %+6.1f°",
	"Chassis x %+5.2f  z %+5.2f   %4.1f m/s": "底盘 x %+5.2f  z %+5.2f   %4.1f m/s",
	"Drive: %s": "驱动: %s",
	"Targets %d   feed 1280×1024   self-FPV %s": "靶机 %d   画面 1280×1024   自身入镜 %s",
	"Camera: %s": "相机: %s",
	"ROS: off": "ROS: 关闭",
	"ON": "开",
	"OFF": "关",

	# --- HUD: drive / camera mode readouts ---------------------------------
	"camera follow (F4 = free)": "跟随视角（F4 = 自由相机）",
	"FREE  %.1f m/s  (WASD / E F)": "自由相机  %.1f m/s（WASD / E F）",
	"follow gimbal (C = toggle)": "跟随云台（C = 切换）",
	"independent (C = toggle)": "独立（C = 切换）",

	# --- HUD: controls panel ----------------------------------------------
	"Q / E    gimbal yaw": "Q / E    云台偏航",
	"R / F    gimbal pitch": "R / F    云台俯仰",
	"W / S    chassis fwd / back": "W / S    底盘前进 / 后退",
	"A / D    chassis strafe": "A / D    底盘横移",
	"Shift    chassis boost": "Shift    底盘加速",
	"C        chassis follow gimbal": "C        底盘跟随云台",
	"F3       operator FPV (mouse aim)": "F3       操作员第一人称（鼠标瞄准）",
	"F1       feed fullscreen": "F1       画面全屏",
	"F2       self in feed": "F2       自身出现在画面",
	"F4       free camera (WASD, E/F up)": "F4       自由相机（WASD，E/F 升降）",
	"Wheel    free-cam speed": "滚轮     自由相机速度",
	"F5       reset pose": "F5       重置位姿",
	"F6       ROS publish on / off": "F6       ROS 发布 开 / 关",
	"F8       reload scenario": "F8       重载场景",
	"F9       next scenario": "F9       下一个场景",
	"Tab      scenario panel": "Tab      场景面板",
	"F10      UI language": "F10      界面语言",
	"Esc      back / quit": "Esc      返回 / 退出",

	# --- HUD: feed preview / fullscreen -----------------------------------
	"FEED 1280×1024  ·  ROS /image_raw + /image_raw/compressed":
		"画面 1280×1024  ·  ROS /image_raw + /image_raw/compressed",
	"F1  back": "F1  返回",

	# --- Scenario panel: chrome -------------------------------------------
	"SCENARIO": "场景",
	"CLOSE": "关闭",
	"RELOAD": "重载",
	"Scenario": "场景",
	"Field": "场地",
	"Targets": "靶机数",
	"TARGET MOTION": "靶机运动",
	"Type": "类型",
	"Mode": "模式",
	"Speed m/s": "速度 m/s",
	"Spin deg/s": "转速 °/s",
	"APPLY MOTION": "应用运动",
	"Camera": "相机",
	"ROS publish": "ROS 发布",
	"SAVE YAML": "保存 YAML",
	"Language": "语言",
	"Tab closes · Esc releases the mouse": "Tab 关闭 · Esc 释放鼠标",

	# --- Scenario panel: status readout -----------------------------------
	"Scenario: %s · Field: %s": "场景: %s · 场地: %s",
	"Targets: %d": "靶机数: %d",
	"Motion: %s": "运动: %s",
	"backend unavailable": "后端不可用",
	"publish ON": "发布 开",
	"publish OFF": "发布 关",
	"Error: ": "错误: ",

	# --- Scenario values shown in the UI (schema values stay untranslated
	#     in YAML; only the labels are localized) ---------------------------
	"static": "静止",
	"line": "直线",
	"polyline": "折线",
	"spin": "旋转",
	"once": "一次",
	"loop": "循环",
	"pingpong": "往返",
	"moving %d: %s": "运动中 %d: %s",

	# --- Main: view / ROS readouts ----------------------------------------
	"THIRD-PERSON": "第三人称",
	"OPERATOR FPV": "操作员第一人称",
	"FREE CAMERA": "自由相机",
	"ROS: not started": "ROS: 未启动",
}

static var _installed := false


## Register the translation tables with TranslationServer (idempotent).
static func install() -> void:
	if _installed:
		return
	_installed = true
	var zh := Translation.new()
	zh.locale = "zh_CN"
	for msgid in ZH_CN:
		zh.add_message(String(msgid), String(ZH_CN[msgid]))
	TranslationServer.add_translation(zh)


## Resolve one msgid in the active locale (English fallback is the msgid).
## install() is explicit (Main calls it at startup) so tests that build a
## Control directly still get the English msgid.
static func t(msgid: String) -> String:
	return TranslationServer.translate(msgid)


## Normalize any locale code to one of SUPPORTED_LOCALES.
static func normalize_locale(locale: String) -> String:
	var code := locale.replace("-", "_").to_lower()
	if code.begins_with("zh"):
		return "zh_CN"
	if code.begins_with("en"):
		return "en"
	return FALLBACK_LOCALE


## OS locale mapped onto the supported set.
static func system_locale() -> String:
	return normalize_locale(OS.get_locale())


## Locale to use at startup: saved preference first, then the OS locale.
static func startup_locale() -> String:
	var saved := saved_locale()
	if saved != "":
		return saved
	return system_locale()


## Switch the UI language now; `persist` writes the choice to user://ui.cfg.
static func set_locale(locale: String, persist := true) -> String:
	install()
	var normalized := normalize_locale(locale)
	TranslationServer.set_locale(normalized)
	if persist:
		save_locale(normalized)
	return normalized


static func get_locale() -> String:
	return normalize_locale(TranslationServer.get_locale())


## Apply the startup preference (saved choice or OS locale) without re-saving.
static func apply_startup_locale() -> String:
	return set_locale(startup_locale(), false)


## Cycle to the next supported locale (used by the F10 shortcut).
static func toggle_locale() -> String:
	return set_locale(next_locale(get_locale()))


static func next_locale(locale: String) -> String:
	var current := normalize_locale(locale)
	var index := SUPPORTED_LOCALES.find(current)
	return SUPPORTED_LOCALES[(index + 1) % SUPPORTED_LOCALES.size()]


## Native display name for a locale ("中文" / "English").
static func locale_display_name(locale: String) -> String:
	var code := normalize_locale(locale)
	return String(LOCALE_NAMES.get(code, code))


## Persisted locale, or "" when the user never picked one.
static func saved_locale() -> String:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return ""
	var value := String(config.get_value(CONFIG_SECTION, CONFIG_KEY, ""))
	if value == "":
		return ""
	return normalize_locale(value)


## Write the locale to user://ui.cfg; failures are non-fatal (headless user://
## may be read-only, in which case the choice simply does not persist).
static func save_locale(locale: String) -> void:
	var config := ConfigFile.new()
	config.load(CONFIG_PATH)
	config.set_value(CONFIG_SECTION, CONFIG_KEY, normalize_locale(locale))
	var err := config.save(CONFIG_PATH)
	if err != OK:
		push_warning("I18n: cannot save %s (%s)" % [CONFIG_PATH, error_string(err)])
