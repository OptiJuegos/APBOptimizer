function Get-WinUtilAboutInfo {
    param(
        [ValidateSet('en', 'es')][string]$Language = 'en',
        [string]$Version = ''
    )

    if ($Language -eq 'es') {
        return @"
APBOptimizer - Versión: $Version

Créditos y agradecimientos
Un saludo a Chris Titus Tech y a toda la comunidad que hizo posible WinUtil.
¡Gracias por compartir WinUtil como software libre! APBOptimizer está basado en ese trabajo.

Proyecto original: <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>
Licencia original: <a href="https://github.com/ChrisTitusTech/winutil/blob/main/LICENSE">Ver licencia MIT</a>
Licencia MIT · Copyright (c) 2022 CT Tech Group LLC.
El aviso de copyright y el texto completo de la licencia se conservan en el archivo LICENSE de APBOptimizer.

Colaboradores de WinUtil:
Autor: <a href="https://github.com/ChrisTitusTech">@ChrisTitusTech</a>
Interfaz: <a href="https://github.com/MyDrift-user">@MyDrift-user</a>, <a href="https://github.com/Marterich">@Marterich</a>
Runspace: <a href="https://github.com/DeveloperDurp">@DeveloperDurp</a>, <a href="https://github.com/Marterich">@Marterich</a>

APBOptimizer es un fork independiente; no está afiliado ni respaldado por Chris Titus Tech.
"@
    }

    return @"
APBOptimizer - Version: $Version

Credits and acknowledgements
Greetings to Chris Titus Tech and everyone who made WinUtil possible.
Thank you for sharing WinUtil as open-source software! APBOptimizer is based on that work.

Original project: <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>
Original license: <a href="https://github.com/ChrisTitusTech/winutil/blob/main/LICENSE">View MIT license</a>
MIT License · Copyright (c) 2022 CT Tech Group LLC.
The original copyright notice and full license text are kept in APBOptimizer's LICENSE file.

WinUtil contributors:
Author: <a href="https://github.com/ChrisTitusTech">@ChrisTitusTech</a>
UI: <a href="https://github.com/MyDrift-user">@MyDrift-user</a>, <a href="https://github.com/Marterich">@Marterich</a>
Runspace: <a href="https://github.com/DeveloperDurp">@DeveloperDurp</a>, <a href="https://github.com/Marterich">@Marterich</a>

APBOptimizer is an independent fork and is not affiliated with or endorsed by Chris Titus Tech.
"@
}
