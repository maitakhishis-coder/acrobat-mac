"""Prepare a disposable copy of the Acrobat SDK's Starter project."""
import re
import shutil
import sys
from pathlib import Path

sdk, source, marker = map(Path, sys.argv[1:])
projects = sorted(sdk.rglob("Starter.xcodeproj"))
if len(projects) != 1:
    sys.exit(f"Se esperaba un Starter.xcodeproj. Encontrados: {projects}")
project = projects[0]
starter = next((p for p in project.parents if p.name.lower() == "starter"), project.parent)
pattern = re.compile(r"\b(PluginInit|PluginUnload)\s*\(\s*(?:void\s*)?\)\s*\{")
candidates = []
for file in starter.rglob("*.cpp"):
    text = file.read_text(encoding="utf-8-sig", errors="replace")
    if {m[1] for m in pattern.finditer(text)} == {"PluginInit", "PluginUnload"}:
        candidates.append((file, text))
if len(candidates) != 1:
    sys.exit("No se pudo identificar de forma inequívoca la inicialización del ejemplo Starter.")
init, content = candidates[0]
# gExtensionID suele definirse en otro archivo del SDK (p. ej. PIMain.cpp).
defined = any("gExtensionID" in f.read_text(encoding="utf-8-sig", errors="replace")
              for ext in ("*.c", "*.cpp", "*.h")
              for f in sdk.rglob(ext))
if not defined:
    sys.exit("No se encontró gExtensionID en ningún archivo del SDK.")
if not re.search(r"\bextern\s+ASExtension\s+gExtensionID\b", content):
    content = "extern ASExtension gExtensionID;\n" + content

for match in reversed(list(pattern.finditer(content))):
    start = match.end()
    depth, end = 1, start
    while end < len(content) and depth:
        depth += (content[end] == "{") - (content[end] == "}")
        end += 1
    if depth:
        sys.exit("El cuerpo de la función de inicialización quedó sin cerrar.")
    body = "return FocalInit(gExtensionID);" if match[1] == "PluginInit" else "return FocalUnload();"
    content = content[:start] + f"\n    {body}\n" + content[end-1:]

for filename in ("FocalGeometry.h", "Geometry.h", "FocalGeometry.mm"):
    shutil.copyfile(source / filename, init.parent / filename)
objc_init = init.with_suffix(".mm")
objc_init.write_text('#include "FocalGeometry.h"\n' + content +
                     '\n#include "FocalGeometry.mm"\n', encoding="utf-8")
init.unlink()
pbx = project / "project.pbxproj"
config = pbx.read_text(encoding="utf-8")
if init.name not in config:
    sys.exit(f"Xcode no referencia el archivo {init.name}.")
config = config.replace(init.name, objc_init.name)
config = re.sub(r"(lastKnownFileType|explicitFileType) = sourcecode\.cpp\.cpp;(?=[^{}\n]*"
                + re.escape(objc_init.name) + r")", r"\1 = sourcecode.cpp.objcpp;", config)
pbx.write_text(config, encoding="utf-8")
marker.write_text(str(project), encoding="utf-8")
