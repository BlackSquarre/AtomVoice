# Política de Privacidad de AtomVoice

Última actualización: 9 de mayo de 2026

AtomVoice es una herramienta de entrada de voz en la barra de menú de macOS. Nos tomamos muy en serio su privacidad. Esta Política de Privacidad explica cómo AtomVoice maneja los datos, utiliza los permisos e interactúa con servicios de terceros.

## 1. Principios Fundamentales

AtomVoice está diseñado para procesar datos localmente en su dispositivo y minimizar la recopilación de datos.

AtomVoice no opera cuentas de usuario, muestra anuncios, incluye SDK de análisis, rastrea el comportamiento del usuario, ni vende, alquila o comparte información personal.

## 2. Qué Datos Procesamos

AtomVoice puede procesar los siguientes datos durante su funcionamiento:

1. **Audio de voz**
   Cuando mantiene pulsada la tecla de activación para comenzar a grabar, AtomVoice accede al micrófono y procesa el audio grabado para el reconocimiento de voz y la visualización de la forma de onda. Después de finalizar la grabación, AtomVoice no guarda el audio en archivos locales ni lo carga en ningún servidor de AtomVoice.

2. **Texto reconocido**
   Los resultados del reconocimiento de voz se muestran temporalmente en una ventana flotante de cápsula y se inyectan en el campo de entrada actual después de que finaliza la grabación. AtomVoice no guarda el historial de texto reconocido.

3. **Contenido del portapapeles**
   Para introducir el texto reconocido en la posición actual del cursor, AtomVoice utiliza temporalmente el portapapeles del sistema para realizar una operación de pegado. La aplicación guarda temporalmente el contenido original del portapapeles antes de la inyección e intenta restaurarlo después. El contenido del portapapeles solo se mantiene brevemente en la memoria local y no se carga en ningún servidor de AtomVoice.

4. **Información relacionada con la accesibilidad**
   AtomVoice utiliza los permisos de accesibilidad de macOS para detectar la tecla de activación, identificar la posición de entrada actual y simular operaciones de pegado. La aplicación no registra sus pulsaciones de teclas ni lee continuamente el texto de otras aplicaciones. Solo lee la información cerca del cursor en el campo de entrada enfocado cuando es necesario, para funciones como la evitación de puntuación duplicada.

5. **Configuración local**
   AtomVoice almacena la configuración de la aplicación localmente, como idioma, motor de reconocimiento, tecla de activación, dispositivo de entrada, estilo de animación, configuración de parada automática por silencio, URL del proveedor LLM, nombre del modelo, indicaciones personalizadas, etc. Estos ajustes se almacenan en las preferencias locales de macOS.

6. **Clave API de LLM**
   Si habilita el refinamiento de texto LLM e ingresa una clave API, AtomVoice almacena la clave API en la configuración local y la utiliza únicamente para realizar solicitudes al proveedor LLM elegido. AtomVoice no carga su clave API en ningún servidor de AtomVoice.

## 3. Cómo Funciona el Reconocimiento de Voz

AtomVoice admite diferentes modos de reconocimiento:

1. **Reconocimiento de voz de Apple**
   De forma predeterminada, AtomVoice utiliza el framework Apple Speech para el reconocimiento de voz. Dependiendo de su versión de macOS, idioma y capacidades del sistema, el reconocimiento de voz puede realizarse en el dispositivo o a través del servicio de reconocimiento de voz de Apple. El manejo de datos relacionados está sujeto a la política de privacidad de Apple.

2. **Modo de reconocimiento en dispositivo de Apple**
   Si habilita "Reconocimiento en dispositivo de Apple" y el idioma actual lo admite, AtomVoice solicita al sistema que realice el reconocimiento solo en el dispositivo.

3. **Reconocimiento local Sherpa ONNX**
   Si configura un modelo de reconocimiento local Sherpa ONNX, el reconocimiento de audio se realiza completamente en su dispositivo sin necesidad de cargarlo en ningún servicio de reconocimiento en la nube.

4. **Reconocimiento en la nube en streaming de Volcengine (Doubao)**
   Si habilita el motor de reconocimiento en la nube en streaming de Volcengine (Doubao) y configura una clave API y un Resource ID, AtomVoice envía su audio de voz al servicio de reconocimiento de voz Volcengine de Bytedance para el reconocimiento en streaming en tiempo real. Sus datos de audio son procesados por los servidores de Volcengine. El manejo de datos relacionados está sujeto a las políticas de privacidad de Bytedance y Volcengine. Esta función requiere configuración en los ajustes de Doubao y está deshabilitada de forma predeterminada.

## 4. Refinamiento de Texto LLM

El refinamiento de texto LLM está deshabilitado de forma predeterminada.

Si habilita esta función, AtomVoice envía el texto reconocido al proveedor LLM configurado para corrección de errores, completado de puntuación o mejora de la transcripción de voz. Los proveedores compatibles incluyen OpenAI, Anthropic, DeepSeek, Moonshot, Alibaba Cloud Bailian, Zhipu AI, Lingyi Wanwu, Groq, API personalizada compatible con OpenAI u Ollama local.

Los datos enviados al proveedor LLM típicamente incluyen:

1. El texto reconocido de la sesión actual
2. Indicación del sistema o indicación personalizada
3. El nombre del modelo configurado
4. La clave API para autenticación

Cómo se manejan estos datos depende del proveedor LLM que elija. Revise la política de privacidad y los términos de uso de datos del proveedor correspondiente antes de usar.

Si no habilita el refinamiento de texto LLM, AtomVoice no enviará texto reconocido a ningún proveedor LLM.

## 5. Verificación Automática de Actualizaciones

AtomVoice verifica nuevas versiones a través de GitHub Releases. Al verificar actualizaciones, la aplicación envía una solicitud a GitHub para obtener la información de la última versión. GitHub puede recibir información de solicitud de red, como dirección IP, información de red del dispositivo y User-Agent, de acuerdo con sus propias políticas.

AtomVoice no envía sus grabaciones, texto reconocido, contenido del portapapeles ni claves API LLM durante las verificaciones de actualización.

## 6. Permisos

AtomVoice requiere los siguientes permisos de macOS:

1. **Permiso de micrófono**
   Se utiliza para grabar su voz para el reconocimiento de voz.

2. **Permiso de reconocimiento de voz**
   Se utiliza para invocar el framework Apple Speech y convertir la voz en texto.

3. **Permiso de accesibilidad**
   Se utiliza para detectar la tecla de activación, identificar posiciones de entrada e inyectar texto reconocido en la aplicación actual.

Puede revocar estos permisos en cualquier momento en Configuración del Sistema de macOS. Revocar los permisos puede impedir que las funciones relacionadas funcionen correctamente.

## 7. Almacenamiento y Eliminación de Datos

AtomVoice no guarda grabaciones de audio, historial de reconocimiento de voz ni crea cuentas de usuario.

Los datos almacenados localmente consisten principalmente en la configuración de la aplicación. Puede eliminar los datos relacionados mediante:

1. Borrando o modificando la configuración de LLM dentro de la aplicación
2. Eliminando las preferencias de la aplicación AtomVoice en macOS
3. Eliminando la aplicación y sus archivos de soporte local relacionados

Si utiliza servicios LLM de terceros o reconocimiento de voz de Apple, administre o elimine los datos relacionados de acuerdo con las políticas del proveedor correspondiente.

## 8. Compartición de Datos

AtomVoice no vende, alquila ni comercializa sus datos personales.

Los datos pueden enviarse a terceros solo en las siguientes situaciones:

1. Al usar el reconocimiento de voz de Apple, el audio o las solicitudes de reconocimiento pueden ser procesados por Apple
2. Al usar el motor de reconocimiento en la nube en streaming de Volcengine (Doubao), el audio de voz es procesado por los servidores de Volcengine
3. Cuando el refinamiento de texto LLM está habilitado, el texto reconocido se envía al proveedor LLM elegido
4. Al verificar actualizaciones, la aplicación accede a GitHub Releases
5. Al usar un punto final API personalizado, los datos se envían al servidor que configuró

## 9. Medidas de Seguridad

AtomVoice minimiza el procesamiento de datos y prioriza las operaciones en el dispositivo. Las solicitudes en línea se envían típicamente a través de HTTPS. Sin embargo, si configura un punto final API personalizado, como una instancia local de Ollama u otra dirección HTTP, verifique la seguridad de ese servicio usted mismo.

Proteja su clave API LLM y evite almacenar credenciales sensibles en dispositivos no confiables o en entornos de cuentas compartidas.

## 10. Privacidad de los Niños

AtomVoice está dirigido a usuarios generales de macOS y no está específicamente dirigido a niños. No recopilamos deliberadamente información personal de niños.

## 11. Cambios en la Política

Podemos actualizar esta Política de Privacidad a medida que cambien las funciones de la aplicación. Los cambios significativos se comunicarán a través de la página del proyecto, las notas de la versión o los avisos dentro de la aplicación.

## 12. Contáctenos

Si tiene preguntas sobre esta Política de Privacidad o cómo AtomVoice maneja los datos, puede contactarnos en:

- Correo electrónico: [atomvoice@outlook.com](mailto:atomvoice@outlook.com)
- GitHub: https://github.com/BlackSquarre/AtomVoice
