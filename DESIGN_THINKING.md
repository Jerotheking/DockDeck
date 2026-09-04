# DockDeck — Design Thinking & Diseño de Producto

**Fecha:** 2026-09-04 · **Fuente de requisitos:** `MOTION_AUDIT.md` (bugs B1–B12)
**Método:** Double Diamond por workstream — Empatizar → Definir (HMW) → Idear (opciones con trade-offs) → Prototipar/medir. Cada workstream incluye su especificación de producto (historia de usuario, comportamiento, criterios de aceptación).

---

## 0. Identidad de producto — el norte que ordena todo

**DockDeck en una frase:** *los estantes laterales de tu Dock que se comportan como si Apple los hubiera hecho.*

Si Apple hubiera hecho shelves, no habría estados que se funden ni contenido que va pegado con cinta: habría **una sola pieza de vidrio que se deforma**. Ese es el estándar. Todo lo demás es táctica.

### Los 6 principios del lenguaje de motion (el "one motion language")

1. **El vidrio es uno.** Collapsed y expanded son el *mismo material deformándose*, nunca dos estados en crossfade.
2. **El contenido hereda la inercia.** Ninguna superficie se mueve sin que su contenido viaje con ella — velocidad, inclinación, arrival.
3. **Cero estados intermedios percibidos.** El seguimiento del Dock y del puntero es función continua, no una máquina de estados con timers visibles.
4. **Rápido donde apunta el usuario; lujoso en el fondo.** Las gesturas dirigidas (hover, expand) son < 250 ms y levemente overdamped. El lujo (float, glow, breathing) vive en lo ambiental.
5. **Nada aparece de la nada.** Toda inserción, movimiento o borrado de contenido se anima. La reconstrucción total de vistas está prohibida.
6. **El usuario afina la sensibilidad.** Los umbrales que se sienten personales (delay de activación, hysteresis) se exponen en Settings con defaults afinados por nosotros.

**El contrato con el usuario:** mueves tu Dock — posición, lado, tamaño, magnificación, auto-hide — y el deck ya está ahí, exactamente en la nueva geometría, *antes* de que tu mirada llegue. Y cuando lo abres, se siente líquido de verdad: contenido que sale del Dock, no un cajón que se estira.

---

## 1. WS-0 — "El reloj interno" (P0: pipeline de lectura + coalescing)

**Requisitos de auditoría que atiende:** B1 (tormenta AX→evaluate), parte de B3 (jitter general), el CPU runaway del build 9.

### Empatizar
El usuario no ve el pipeline, pero lo *siente*: micro-stutter en la magnificación, UI congelada, ventilador. Ninguna curva de animación puede verse bien sobre una main thread ahogada por IPC síncrono. Es el único workstream que **desbloquea a todos los demás**.

### Definir
**¿Cómo podríamos reaccionar a cada cambio del Dock sin pagar una lectura AX por cada notificación?**

### Idear
- **A. Ventana de coalescing fija (30–50 ms):** el observer solo marca `dirty`; una evaluación max cada 40 ms. Simple, predecible, añade ≤ 40 ms de latencia inherente.
- **B. Dirty-flag por runloop tick:** evaluar en el próximo tick del runloop, sin timer. Latencia mínima, pero una ráfaga de eventos a 240 Hz sigue produciendo 240 ticks trabajados.
- **C. Throttle de lecturas (el viejo `pointerThrottle`):** ya lo vivimos — muestrea y se ve a saltos.
- **Decisión: A + B híbrido.** `dirty` por evento, evaluación agendada al próximo tick **pero nunca antes de 33 ms** desde la última. Un solo `DockGeometry.current()` por evaluación, idempotente, no re-entrante. Promoción de transitoria→confirmada por *lecturas repetidas* contadas en el modelo (sin `asyncAfter` en cascada). Subscripción del sensor reducida a lo que reporta geometría (fuera `AXValueChanged`/`AXTitleChanged`).

### Producto
- **Historia:** *"Cuando mi Dock magnifica, el deck lo sigue fluido y mi Mac no se calienta."*
- **Criterios de aceptación:**
  - CPU del proceso < 2 % en reposo; sin crecimiento durante 5 min de magnificación continua.
  - Máximo **un** `onChange` por evaluación; dos lecturas idénticas consecutivas no emiten nada.
  - Magnificación a 60 fps sin eventos AX encolados (verificable con `sample` del proceso).
- **Métrica:** estabilidad del runloop (hitches/seg ≈ 0) durante la prueba de magnificación.

---

## 2. WS-1 — "El contenido hereda la inercia" (P1)

**Requisitos:** B2 (springs mueven solo el frame), B11 (ejes acoplados — se resuelve junto a WS-5).

### Empatizar
Lo que el usuario describe como "se siente vacío, mecánico" es exactamente la foto de auditoría: la superficie fluye con springs de primer nivel y el contenido va rigid attach. El ojo humano detecta de inmediato material que no se comporta como material.

### Definir
**¿Cómo podríamos hacer que el contenido *sienta* la velocidad de la superficie que lo contiene?**

### Idear
- **A. Vector de motion al contenido:** el spring del panel publica (posición, velocidad) → un `contentMotion` aplicado al host existente (`contentScaleHost`): contra-scale sutil + skew proporcional a la velocidad. Barato (transform, sin relayout), continua.
- **B. Cadena de retraso por tile (lag chain):** cada tile sigue al anterior con un frame de retraso — efecto "cola de pez" pronunciado. Vistoso pero fácil de que se lea *wobbly* (el defecto que ya nos gusta menos del `.expand`).
- **C. Migrar todo a `NSGlassEffectContainerView` y dejar que el sistema mueva el contenido:** máxima fidelidad pero acoplada a macOS 26 y a rehacer la jerarquía.
- **Decisión: A ahora, C absorbe lo suyo en WS-2.** Límites de gusto: skew ≤ 2.5°, contra-scale ≤ 1.04 — *inercia perceptible, no gelatina*. Respeta Reduce Motion (se desactiva).

### Producto
- **Historia:** *"Cuando el deck viaja a su nueva posición, siento que es un objeto con masa, no un rectángulo con decal."*
- **Criterios de aceptación:** agitar la ventana (dock cambia de lado) muestra al contenido inclinándose en la dirección del viaje y asentándose con la superficie; con Reduce Motion activo, cero skew.
- **Métrica:** subjetiva dirigida — "se ve con masa" en la prueba de slide.

---

## 3. WS-2 — "Una sola pieza de vidrio" (P1: morph de expansión)

**Requisitos:** B3 (hueco de 80 ms + crossfade), principio 1.

### Empatizar
El momento más importante de la app — la expansión — es hoy su peor frame: vidrio vacío estirándose 80 ms antes de que exista el primer row, luego un crossfade que el propio código confiesa como rendición.

### Definir
**¿Cómo podría el shelf expandirse sin dejar de ser el mismo material ni un solo frame?**

### Idear
- **A. `NSGlassEffectContainerView` (macOS 26):** collapsed y expanded como dos glass views del *mismo* container — el sistema hace el morph fluido entre ellas. Es la API con la que Apple construye exactamente este efecto.
- **B. Fallback sin 26:** montar el contenido expanded **en el primer frame** (nada de `asyncAfter 0.08`), fade de 0.10 s, arrivals arrancando en el frame 1.
- **C. Un solo layout flexible** (la tira y la expanded son la misma vista que cambia de tamaño): máxima pureza, riesgo alto de "garbage frame" al reflow — el problema original que produjo el crossfade.
- **Decisión:** A como camino principal (la app ya vive en macOS 26 con `NSGlassEffectView`), B como fallback garantizado. C queda descartado salvo que A falle en device.

### Producto
- **Historia:** *"Cuando toco el borde, el estante brota del Dock — una pieza que crece, no un reemplazo."*
- **Criterios de aceptación:** el primer row existe en el **frame 1** de la expansión; ningún crossfade percibible entre estados; el material durante el morph muestra el specular continuo (no un pop de opacidad).
- **Métrica:** captura de frames durante expansión: 0 frames con "vidrio vacío".

---

## 4. WS-3 — "El lenguaje del Dock": hover gaussiano por tile (P1)

**Requisitos:** auditoría 2.7.2 (el tile solo se escala a sí mismo; el Dock magnifica toda la fila por distancia).

### Empatizar
El usuario lleva 20 años mirando el Dock: su hover tiene una gramática — el ícono bajo el puntero crece más, los vecinos decaen suavemente con la distancia. Nuestro hover binario por tile se lee foráneo junto a él.

### Definir
**¿Cómo podría el hover del deck usar la misma gramática que el Dock ya le enseñó al usuario?**

### Idear
- **A. Gaussiana por distancia** (radio ~1.5 tiles, escala pico 1.14): escala de cada tile = f(distancia del puntero), evaluada en un display link compartido mientras el puntero esté sobre la tira. Función directa del puntero — latencia cero, igual que el Dock (principio 3).
- **B. Springs por tile con retarget:** más "springy" pero N springs peleándose = el jitter que ya conocemos.
- **C. Solo el tile bajo el puntero** (status quo): descartado — es la foraneidad que queremos matar.
- **Decisión: A.** Un solo evaluador, N transforms — el patrón del Dock reconstruido con API pública.

### Producto
- **Historia:** *"El deck se siente de la misma familia que el Dock: donde pongo el cursor, la tira responde a mi alrededor."*
- **Criterios de aceptación:** mover el puntero por la tira produce una onda suave de escalas proporcionales a la distancia; al salir, decae sin overshoot; Reduce Motion lo degrada a hover simple.

---

## 5. WS-4 — "Nada aparece de la nada": diffing de contenido (P1)

**Requisitos:** B4 (reconstrucción total en cada reload), B10 (botones sin fade).

### Empatizar
Copiar tres cosas al portapapeles hoy significa: la tira entera parpadea, ningún ícono nuevo entra con animación, y la superficie más mirada de la app se comporta como una tabla HTML sin CSS. Dockside le llama a su versión "visual item tracking"; el Dock anima cada inserción individual.

### Definir
**¿Cómo podría el contenido cambiar de composición sin que el usuario vea un solo parpadeo?**

### Idear
- **A. Diff manual por identidad** (key = ítem): insertar con arrival (slide desde la cara del Dock + scale), mover con fade-through, borrar con shrink-fade. Mantiene nuestro chrome custom intacto.
- **B. `NSCollectionView` + diffable data source:** animaciones gratis, pero reescribe la capa de vista y pelea con el material glass.
- **C. `NSStackView` con `visibilityPriority`:** hack frágil, sin control del motion.
- **Decisión: A.** El diff es un modelo puro (testeable en `ModelSelfTest` como todo lo demás): `DiffResult = {inserts, moves, removes}` sobre ids.
- **Extra del mismo workstream:** fade 0.12 s en los botones de fila y fade+slide del overflowLabel (B10).

### Producto
- **Historia:** *"Cuando agrego algo, lo veo llegar — el deck tiene continuidad, no cortes."*
- **Criterios de aceptación:** pegar N ítems anima N arrivals escalonados (stagger 30–45 ms); cero parpadeo en tiles existentes (verificable: ninguna vista existente se destruye en un reload); los botones de fila aparecen/desaparecen con fade.
- **Métrica:** conteo de teardowns de vista por cambio = 0 para tiles no afectados.

---

## 6. WS-5 — "Rápido donde apunta el usuario": rebalance de carácter (P2)

**Requisitos:** B5 (overshoot sobre sombra), B8 (slide 0.45 s llega tarde), B11 (ejes acoplados).

### Empatizar
Hoy el lujo está invertido: la gestura principal rebota (se lee barato) y la reubicación estructural llega tarde (se lee bug). Es la diferencia entre "líquido" y "wobbly" — y el usuario ya la nombró.

### Definir
**¿Cómo podría cada gestura tener el carácter exacto que su significado exige?**

### Idear / Decisión (tabla de la auditoría, adoptada)
| Preset | Antes | Nuevo | Racional |
|---|---|---|---|
| `.reveal` | 0.30 / 0.78 | **0.26 / 0.90** | Aparición sin rebote: overshoot en un fade-in se lee como error |
| `.expand` | 0.42 / 0.68 | **0.34 / 0.86** | El bote se reserva para el *contenido* (arrivals), no para el frame |
| `.slide` | 0.45 / 0.90 | **0.32 / 0.92** | Reubicación estructural: decidida, llega antes que la mirada |
| `.collapse` | 0.24 / 0.85 | 0.24 / 0.85 | Ya está bien |
| `.track` | 0.13 / 0.95 | 0.13 / 0.95 | El correcto — intacto |

- **Ejes disociados** en `SpringAnimator`: posición `.track`, tamaño `.expand` por componente — durante la magnificación el shelf ya no hace gelatina horizontal.
- **Disciplina de sombra:** durante springs con overshoot, radio de sombra reducido — la sombra amplifica el rebote.

### Producto
- **Criterios de aceptación:** expansión percibe asentada en ≤ 400 ms; slide completa en ≤ 350 ms; magnificación sin componente horizontal de rebote.

---

## 7. WS-6 — "La sensibilidad es tuya": hysteresis + Settings (P2)

**Requisitos:** B12 (flap en el borde, delay fijo 0.45 s). **Lección Dockside:** su fluidez *perceived* viene tanto del afinado como de que el usuario puede afinar.

### Empatizar
El flap nervioso al rozar el borde no es un bug de timing — es la ausencia de hysteresis espacial: el mismo umbral para entrar y salir garantiza oscilación en el límite.

### Definir
**¿Cómo podría el deck abrirse cuando lo intentas y cerrarse solo cuando de verdad te fuiste?**

### Idear / Decisión
- **Hysteresis espacial:** expandir con entrada de ~8 pt dentro de la zona; colapsar tras salir ~28 pt **y** el delay. Entrada fácil, salida deliberada.
- **Settings (nueva pestaña "Comportamiento"):**
  - *Activación:* delay slider 0.10–1.00 s (default 0.45 s).
  - *Zona:* slider de margen 8–48 pt (default 28 pt).
  - *Calma:* modo esconder / desvanecer / ambos — el "hide & fade" de Dockside, que nosotros no tenemos: el fade mantiene una presencia fantasma que es más calmada que desaparecer.
- Los defaults son los afinados por nosotros (principio 6); los sliders son la válvula de escape del "a mí me gusta más lento".

### Producto
- **Criterios de aceptación:** con defaults, 20 pasadas de borde no producen flap; settings persisten entre launches; la prueba de rozamiento con delay=1.0 s es calmada.

---

## 8. WS-7 — Micro-pulido que se acumula (P2)

**Requisitos:** B6, B7, B9, B10, glow ciego al Dock.

Piezas pequeñas, cada una con su criterio, que juntas son el "super polished":

1. **Glow con interpolación** — lerp spring hacia el puntero (nunca teletransporta); al llegar a reposo, breathing sutil. *Criterio: sin saltos entre muestras de mouse.*
2. **Glow que reacciona al Dock** — el eje de la luz se inclina hacia el Dock durante la magnificación: el highlight especular responde al evento más dramático del sistema. *Criterio: visible en la prueba de magnificación.*
3. **Float perpetuo inconmensurable** — dos ejes con periodos 5.3 s y 7.1 s: el ciclo compuesto jamás repite; se elimina el "reset" perceptible del loop. *Criterio: 10 min observando sin ver el patrón.*
4. **Crecimiento continuo** — cuando el Dock crece, `contentScale` anima brevemente > 1 antes de re-derivarse (el clamp de layout ya protege); el brinco desaparece. *Criterio: agrandar el Dock no produce salto visible.*
5. **Press físico completo** — `releasePressed` parte de la presentación actual (no del modelo): cero saltos al soltar a mitad del press. *Criterio: cancelar el press a mitad de camino es continuo.*

---

## 9. Mapa de ejecución (orden y dependencias)

```
WS-0 (pipeline) ──┬── WS-2 (morph) ── WS-1 (inercia)     [PR 1+2: el corazón]
                  ├── WS-4 (diffing)                      [PR 3: independiente]
                  ├── WS-3 (gaussiana)                    [PR 4: independiente]
                  └── WS-5 → WS-6 → WS-7                  [PR 5: pulido final]
```

WS-0 primero siempre: nada se aprecia sobre un runloop ahogado. WS-2 y WS-1 tocan la misma área (panel + material) y van juntos. WS-3 y WS-4 son independientes y paralelizables. WS-5/6/7 son el pase de pulido que cierra.

## 10. Scoreboard (cómo sabremos que ganamos)

| Métrica | Hoy | Meta |
|---|---|---|
| CPU en reposo | runaway (10 GB reportado) | < 2 % |
| Latencia dock-change → settled | percepción de "no se adecua" | < 120 ms estructural; tracking = función del puntero |
| Frames de "vidrio vacío" por expansión | ~5 (80 ms + fade) | 0 |
| Teardowns de vistas por cambio de contenido | todos | 0 para tiles no afectados |
| Flap en borde (20 pasadas) | frecuente | 0 con defaults |
| Veredicto subjetivo | "no me satisfacen" | "esto lo hizo Apple" |

---

*Este documento es el contrato de diseño. Cada PR de motion cita el workstream que implementa y sus criterios de aceptación. La auditoría técnica viva vive en `MOTION_AUDIT.md`.*
