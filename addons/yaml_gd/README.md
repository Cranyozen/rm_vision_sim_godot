# yaml_gd — vendored YAML parser

Pure-GDScript YAML parser used by the Phase 3 scenario layer. It turns a YAML
file into Godot `Dictionary` / `Array` / scalar values and has no engine
integration, so it needs **no plugin and no autoload**: load it with
`YAMLParser.new().parse(text)`.

- Origin: <https://github.com/lowlevel-1989/YAML.gd>
- Vendored commit: `da258fc49ab3de88fb2af6f7400ece3800e779e7`
  ("Merge pull request #7 from brohd11/add-string-safety")
- Upstream path: `addons/yaml_dot_gd/`
- Licence: MIT, see `LICENSE` in this directory (Copyright (c) 2025
  Vinicio Valbuena / lowlevel.1989). The vendored file is unmodified.

## Usage

```gdscript
const YAMLParser := preload("res://addons/yaml_gd/yaml.gd")

var parser := YAMLParser.new()
var data: Variant = parser.parse(FileAccess.get_file_as_string(path))
```

Parser notes that matter for the scenario files:

- Indentation is counted in **spaces** only (tabs are not treated as indent),
  so scenario YAML uses 2-space indentation.
- Scalars are typed automatically: `true` / `false` / `null`, ints and floats.
  Quote a value when it must stay a string (for example `number: "3"`).
- Inline sequences (`[0.0, 0.0, 2.2]`) are supported; inline mappings are only
  handled in the simple `{key: value}` form. Block mappings used by the
  scenario schema contain no inline mappings.
