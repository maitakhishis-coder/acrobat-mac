# Focal Geometry para Acrobat Pro en macOS

Paquete de desarrollo. Incluye el diálogo AppKit, el cálculo de geometría y el código que dibuja el TrimBox azul como guía del visor. El destino es un complemento universal para Intel y Apple Silicon.

## Compilación en un Mac o en un ejecutor macOS con Xcode

Ejecutar desde la carpeta de trabajo, con el DMG original de Adobe accesible:

```sh
bash build-macos.sh /ruta/Acrobat_DC_SDK_Mac_2023_V5.dmg
```

El script monta el DMG en solo lectura, copia el SDK a una carpeta temporal, prepara el ejemplo Starter y verifica ambas arquitecturas del resultado. La ruta prevista es `dist/FocalGeometry.acroplugin`. El binario de compilación queda pendiente de firma para distribución.

## Validación pendiente

La prueba independiente del cálculo C++ y la comprobación de sintaxis del script pasaron en Linux. Aquí no se ha ejecutado Xcode y no se ha comprobado el montaje del DMG, la compatibilidad del proyecto Starter concreto ni la carga del complemento en Acrobat Pro. El siguiente paso es ejecutar el script en macOS, ajustar cualquier diferencia del SDK y verificar geometría y guía en Acrobat Pro con PDF rotado, vista doble y un PDF con tinta plana. Para entregar al usuario final, firmar con Developer ID, preparar un paquete de instalación y notarizarlo.
