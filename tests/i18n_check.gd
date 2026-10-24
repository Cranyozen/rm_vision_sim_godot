extends SceneTree

## Headless check for the operator UI i18n layer (scripts/ui/I18n.gd).
##
## Verifies that the zh_CN table is complete and well formed (non-empty values,
## matching %-placeholders), that every literal msgid used by the UI scripts has
## a translation, that locale switching / cycling works, and that the choice
## persists in user://ui.cfg when user:// is writable.
##
## Run: godot --headless --path . --script res://tests/i18n_check.gd
## Expects: I18N_CHECK: PASS

const UI_SOURCES: Array[String] = [
	"res://scripts/ui/HUD.gd",
	"res://scripts/ui/ScenarioPanel.gd",
	"res://scripts/app/Main.gd",
]

## tr("...") / I18n.t("...") calls with a literal msgid.
const CALL_PATTERN := "(?:tr|I18n\\.t)\\(\"((?:[^\"\\\\]|\\\\.)*)\"\\)"
## printf-style placeholder (%s, %d, %5.1f, %+6.1f, %%, ...).
const PLACEHOLDER_PATTERN := "%[-+ 0#]*[0-9]*(?:\\.[0-9]+)?[a-zA-Z%]"

var _failures: Array[String] = []


func _initialize() -> void:
	I18n.install()
	I18n.install()  # idempotent

	_check(I18n.SUPPORTED_LOCALES.has("en") and I18n.SUPPORTED_LOCALES.has("zh_CN"),
		"supported locales include en + zh_CN")

	# --- English fallback ---------------------------------------------------
	I18n.set_locale("en", false)
	_check(I18n.t("SCENARIO") == "SCENARIO", "en falls back to the msgid")
	_check(I18n.t("F10      UI language") == "F10      UI language",
		"en leaves the F10 hint unchanged")

	# --- Chinese translation ------------------------------------------------
	I18n.set_locale("zh_CN", false)
	_check(I18n.get_locale() == "zh_CN", "locale switches to zh_CN")
	_check(I18n.t("SCENARIO") == "场景", "zh_CN translates SCENARIO")
	_check(I18n.t("F10      UI language") == "F10      界面语言",
		"zh_CN translates the F10 hint")
	_check(I18n.t("THIRD-PERSON") == "第三人称", "zh_CN translates the view name")
	_check(I18n.t("ROS: not started") == "ROS: 未启动", "zh_CN translates the ROS readout")
	_check(I18n.t("not a translated msgid") == "not a translated msgid",
		"zh_CN leaves unknown msgids alone")

	# --- table hygiene ------------------------------------------------------
	var placeholder_regex := RegEx.new()
	placeholder_regex.compile(PLACEHOLDER_PATTERN)
	for msgid_value in I18n.ZH_CN:
		var msgid := String(msgid_value)
		var translated := String(I18n.ZH_CN[msgid])
		_check(msgid.strip_edges() != "", "msgid is not empty")
		_check(translated.strip_edges() != "",
			"zh_CN value is not empty: %s" % msgid)
		var source_specs := _placeholders(placeholder_regex, msgid)
		var target_specs := _placeholders(placeholder_regex, translated)
		_check(source_specs == target_specs,
			"placeholders match for '%s' (%s vs %s)" % [msgid, source_specs, target_specs])

	# --- every literal msgid used by the UI has a translation ---------------
	var call_regex := RegEx.new()
	call_regex.compile(CALL_PATTERN)
	var used := 0
	for path in UI_SOURCES:
		var text := FileAccess.get_file_as_string(path)
		_check(text != "", "UI source readable: %s" % path)
		for match_result in call_regex.search_all(text):
			var msgid := match_result.get_string(1)
			if msgid.contains("\\"):
				continue
			used += 1
			_check(I18n.ZH_CN.has(msgid),
				"literal msgid has a zh_CN translation: '%s' (in %s)" % [msgid, path])
	_check(used > 40, "scanned a meaningful number of msgids (%d)" % used)

	# --- locale cycling / normalization ------------------------------------
	I18n.set_locale("en", false)
	_check(I18n.next_locale("en") == "zh_CN", "next_locale(en) is zh_CN")
	_check(I18n.next_locale("zh_CN") == "en", "next_locale(zh_CN) is en")
	_check(I18n.normalize_locale("zh-Hans") == "zh_CN", "zh-Hans normalizes to zh_CN")
	_check(I18n.normalize_locale("zh_TW") == "zh_CN", "zh_TW normalizes to zh_CN")
	_check(I18n.normalize_locale("en_GB") == "en", "en_GB normalizes to en")
	_check(I18n.normalize_locale("de_DE") == "en", "unknown locales fall back to en")
	_check(I18n.locale_display_name("zh_CN") == "中文", "zh_CN display name is 中文")
	_check(I18n.locale_display_name("en") == "English", "en display name is English")

	# --- persistence (skipped when user:// is not writable) ----------------
	# Some sandboxes expose user:// read-only (ConfigFile.save() fails); the
	# choice then simply does not persist, which is not an i18n bug.
	var writable := _user_dir_writable()
	var original_saved := I18n.saved_locale()
	if writable:
		I18n.save_locale("zh_CN")
		_check(I18n.saved_locale() == "zh_CN", "locale choice persists in user://ui.cfg")
		_restore_saved_locale(original_saved)
		_check(I18n.saved_locale() == original_saved,
			"persisted locale restored after the check")
	else:
		print("SKIP  user:// not writable; persistence check skipped")

	# Leave the editor-less run in a deterministic state.
	I18n.set_locale("en", false)

	if _failures.is_empty():
		print("I18N_CHECK: PASS")
		quit(0)
	else:
		for failure in _failures:
			printerr("FAILED: ", failure)
		print("I18N_CHECK: FAIL (%d)" % _failures.size())
		quit(1)


## Placeholder tokens in order, ignoring the literal "%%" escape.
func _placeholders(regex: RegEx, text: String) -> Array[String]:
	var out: Array[String] = []
	for match_result in regex.search_all(text):
		var token := match_result.get_string()
		if token == "%%":
			continue
		out.append(token)
	return out


## True when user:// accepts a file write (some sandboxes block it).
func _user_dir_writable() -> bool:
	var probe := "user://.i18n_write_probe"
	var file := FileAccess.open(probe, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string("x")
	file.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(probe))
	return true


func _restore_saved_locale(original: String) -> void:
	if original == "":
		var config := ConfigFile.new()
		config.load(I18n.CONFIG_PATH)
		config.set_value(I18n.CONFIG_SECTION, I18n.CONFIG_KEY, "")
		config.save(I18n.CONFIG_PATH)
	else:
		I18n.save_locale(original)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS  ", message)
	else:
		printerr("FAIL  ", message)
		_failures.append(message)
