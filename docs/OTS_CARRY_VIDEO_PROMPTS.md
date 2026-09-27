# OTS Carry Walk Video Prompts

These prompts are written for an 8-second, 24 fps reference render from
`demos/ots_carry_clay_proxy.tscn`. The Godot render is a blocking and motion
reference only: replace the clay geometry with realistic human performers and
real street details. Keep the reference camera path and composition continuous.

## Kling 3.0

Use the rendered OTS carry proxy video as the motion and camera reference. Generate an 8-second photorealistic live-action night scene on a Dongguan coffee-shop street. Preserve the exact over-the-shoulder camera path, framing, screen direction, timing, relative positions, and walking route from the reference video. Do not treat the gray clay surfaces as final materials and do not reproduce the proxy topology literally.

The foreground subject is a realistic adult man carrying a realistic adult woman over his right shoulder in a secure fireman's-carry position. The man is the locomotion driver and controls all world translation. Animate a physically credible loaded walk: shorter steps, a slightly wider base, visible knee and ankle compression, heel-to-toe foot contacts, controlled vertical bounce, reduced arm swing, shoulders and pelvis counter-rotating to balance the load, a slight forward trunk lean, and subtle side-to-side compensation. His planted feet must never slide, pop, teleport, or lose contact with the pavement. Maintain believable weight transfer at every step.

The woman remains supported on the man's shoulder throughout. Keep her torso, pelvis, and upper thigh in stable contact with his shoulder and supporting arms. Add secondary inertial motion only after the man's body moves: a small delayed sway of her torso, soft head lag, loose arm and hand follow-through, and restrained leg wobble. The motion must look like a heavy, unconscious or exhausted person being carried, not a dancing or weightless ragdoll. Do not let her drift away from the shoulder, pass through the carrier, straighten into a standing pose, or become fused with him. Preserve both identities and anatomy with two clearly separate bodies.

Convert the monochrome proxy street into a realistic but subdued Dongguan night street: wet asphalt, practical storefront lighting, physically plausible reflections, restrained coffee-shop signage, ordinary parked street details, and natural atmospheric depth. No neon cyberpunk styling, game-like outlines, clay shading, exaggerated bloom, fantasy lighting, extra pedestrians, vehicles crossing the shot, or text overlays. Keep the OTS composition readable, with the carrier's gait and the carried woman's contact points visible. Use natural handheld steadiness with the same smooth camera motion as the reference, no cuts, no zoom jumps, no reframing, and no new camera angle. End with the man still walking in a stable loaded gait while the woman remains securely supported.

Negative constraints: no foot sliding; no floating; no teleportation; no sudden speed changes; no extra limbs or fingers; no twisted spines; no identity swap; no duplicate people; no body merging; no shoulder penetration; no clothing or anatomy flicker; no camera cuts; no change of lens or field of view; no clay or wireframe appearance in the final output.

## MiniMax H3

```text
subject_definitions:
<Subject 1> is the adult male carrier represented by the foreground male proxy in <Video 1>; preserve his body proportions and screen position while replacing the proxy with a realistic adult man.
<Subject 2> is the adult female being carried represented by the female proxy in <Video 1>; preserve her body proportions, carried orientation, and contact relationship while replacing the proxy with a realistic adult woman.
<Subject 3> is the Dongguan coffee-shop street represented by the clay environment in <Video 1>; use it as a layout and lighting-blocking reference only, then render a realistic wet night street without retaining clay shading or literal proxy topology.
<Video 1> is the continuous OTS carry blocking render from demos/ots_carry_clay_proxy.tscn. It provides the camera path, framing, timing, screen direction, relative placement, and broad motion timing; it is not a source for final materials, colors, textures, or mesh topology.

summary:
[reference generation] Generate an 8-second photorealistic live-action OTS carry walk using <Video 1> as the motion, camera, and blocking reference. <Subject 1> performs a realistic loaded gait while carrying <Subject 2> over one shoulder through <Subject 3>. Preserve the continuous camera composition and relative contact layout, but replace all clay proxies with anatomically credible people and a subdued realistic Dongguan night street.

retention_analysis:
<Subject 1> (appears in [Shot 1]): fully_preserved - preserve the carrier's screen position, facing direction, walking route, step timing, and interaction with the carried body while transferring the proxy form to a realistic adult male.
<Subject 2> (appears in [Shot 1]): fully_preserved - preserve the carried orientation, shoulder/torso/pelvis/thigh contacts, delayed secondary motion, and supported relationship while transferring the proxy form to a realistic adult female.
<Subject 3> (appears in [Shot 1]): attribute_transfer - transfer the proxy street's layout, depth cues, storefront arrangement, and practical-light positions into a realistic wet Dongguan night street; do not preserve gray clay materials, wireframe cues, neon-game styling, or literal mesh topology.
<Video 1> (camera path and temporal blocking): fully_preserved - preserve the continuous OTS camera motion, framing, lens impression, screen direction, relative timing, and no-cut structure; use the video only as a guide for motion and composition.

detailed_description:
The target video is a single continuous photorealistic live-action shot at night, with natural low-key street lighting, wet pavement reflections, realistic depth of field, and restrained handheld steadiness. There are no cuts, no camera angle changes, and no new subjects.
[Shot 1] The shot opens with the exact composition and screen direction established by <Video 1>. <Subject 1>, a realistic adult man, occupies the foreground and walks forward while carrying <Subject 2>, a realistic adult woman, over his right shoulder in a secure fireman's-carry position. He is the locomotion driver and translates through the world; the camera follows the same smooth OTS path and maintains the same relative framing as <Video 1>. The man's gait is visibly loaded: shorter stride length, slightly wider foot placement, increased knee and ankle compression, heel-to-toe foot contacts, controlled vertical bounce, reduced arm swing, mild forward trunk lean, and subtle shoulder and pelvis counter-rotation to keep balance. Each planted foot remains firmly attached to the pavement with no sliding or popping. His supporting arms visibly stabilize the woman's thigh and waist without penetrating her body.

<Subject 2> remains heavy and supported. Her torso and pelvis stay in contact with the carrier's shoulder and arms while following his movement with a small delayed inertial sway. Her head lags subtly behind the carrier's acceleration, and her loose arms and lower legs follow with restrained secondary wobble. The delay is soft and physically plausible, never a weightless ragdoll effect. She must not straighten, stand, drift away, pass through the carrier, or fuse with him. Preserve two separate anatomies, natural contact shadows, and believable compression at the shoulder and hip contact points.

Transfer <Subject 3>'s blocked street layout into a realistic Dongguan coffee-shop street: wet asphalt, ordinary storefront façades, practical lamps, muted interior light, believable reflections, and mild humid night atmosphere. Keep the street visually subordinate to the loaded walk. Do not add crowds, crossing cars, neon cyberpunk color, game outlines, clay materials, exaggerated bloom, text overlays, or logos. Continue the same OTS camera path without zoom jumps, reframing, field-of-view changes, or cuts. During the final second, the man is still walking with a stable loaded gait and the woman remains securely supported, with no reset pose or abrupt freeze.

overall_soundscape:
Quiet humid night-street ambience, distant traffic wash, faint storefront HVAC, soft footfalls on wet pavement, subtle clothing friction, and restrained carrier breathing. Footstep timing follows the visible heel-to-toe contacts. No dialogue and no added crowd voices.

non_diegetic_music:
N/A. Do not add music; keep the result useful for later motion analysis and gait migration.
```

For motion migration, compare the generated clips by inspecting the carrier's heel strikes, stance duration, pelvis height, trunk compensation, and the phase-delayed motion of the carried woman's torso. The best clip is the one with stable foot contacts and a consistent carried-body relationship, even if its visual styling is less dramatic.
