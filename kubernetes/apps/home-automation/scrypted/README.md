# Scrypted / Reolink second-generation doorbell

## Delivery status

Prepared locally, not deployed. The Flux Kustomization is suspended deliberately.
The doorbell is online at `192.168.1.17`. No plugin, Apple Home pairing, notification,
two-way audio or UniFi recording acceptance test has passed yet.
Do not mark the Scrypted task as passing until those live checks are recorded.

Target hardware: `DBB_NT19DNO34MPW6DBB3`.
Target firmware: `v3.0.0.7261_26092204`.
Authenticated ONVIF inspection on 2026-10-13 confirmed that firmware and two
profiles: `Preview_01_main` (2048×2048 at 15 fps) and
`Preview_01_sub` (720×720 at 15 fps). Live RTSP probes confirmed H.265/AAC
on the main stream and H.264/AAC on the substream, despite ONVIF incorrectly
reporting H.264 for both. Select the substream for HomeKit compatibility;
Frigate copies the main stream for recording. ONVIF listens on port 8000 and RTSP on
554. HTTP, HTTPS, RTMP and the vendor service ports refused connections.
Use the ONVIF plugin with `admin` and port 8000 for the initial import; the
Reolink plugin's HTTP/RTMP path is unavailable with the current camera settings.
Do not enable those services or change codecs merely to match older examples.
ONVIF video working in UniFi Protect is owner-supplied evidence; it does not
prove doorbell events or ONVIF audio backchannel support.

## Frigate rollout dependency (2026-10-13)

The doorbell configuration is validated locally but not active. Live Frigate
uses `frigate-media-ssd`; `main` still declares `frigate-media`. Its Flux
Kustomization is suspended. Do not resume it with the old claim: publish the
existing storage owner’s SSD configuration first, or include that narrowly
reviewed dependency in the approved rollout. The doorbell change itself does
not alter storage. Keep seven days of motion recordings and thirty days of
snapshots, inherited from the existing configuration.

## Deployment and isolation

The app has its own single-replica Deployment, Longhorn RWO 10 GiB PVC mounted
at `/server/volume`, Service and internal authenticated HTTPRoute. Recreate
avoids concurrent writers to Scrypted's database. Scrypted uses host networking
for HomeKit mDNS, accessory TCP connections and RTP traffic. The HTTPRoute only
serves administration; it does not carry HomeKit traffic. Native Scrypted login
still protects direct LAN access to port 10443. Do not expose it on the Internet.
The scoped Traefik ServersTransport accepts Scrypted's self-signed backend TLS.

Read-only cluster inspection on 2026-10-10:

| Node | IP | Rockchip device users |
| --- | --- | --- |
| node-0b0715 | 192.168.1.186 | Frigate: `/dev/dri`, `/dev/dma_heap`, `/dev/rga`, `/dev/mpp_service` |
| node-0b06df | 192.168.1.27 | No pods mounting those devices |
| node-0b06a7 | 192.168.1.233 | No pods mounting those devices; Home Assistant uses host networking |

All nodes are ARM64 RK3588. None advertises an allocatable NPU/VPU device
resource. Frigate's hostPath mounts do not reserve devices with Kubernetes.
Required pod anti-affinity keeps Scrypted off a node already running Frigate.
The normal Kubernetes scheduler also honours existing pods' required
anti-affinity when scheduling a replacement Frigate pod, so no reciprocal change
to Frigate is needed. If no separate eligible node is available, the new pod
stays Pending. This is a scheduling rule, not runtime eviction: bypassing the
scheduler or changing labels on running pods can violate separation.
Adding the doorbell to Frigate is now in scope and requires a configuration
restart; keep the existing Birdy stream settings unchanged. The base Scrypted deployment mounts no host
devices and uses stream copy/software FFmpeg, so it cannot compete for the NPU/VPU.

Before rollout, inspect the chosen node for listeners on 10443/11080 and existing
Avahi/mDNS services. Check current upstream host-network Avahi guidance against
the pinned image, not just the newest compose file. Do not disable host services
as part of this deployment. Select a compatible HomeKit advertiser and confirm
discovery with the existing services still running. Select the wired node IP in
Scrypted Server Address. Check Apple hubs can reach that subnet and UDP 5353,
the advertised accessory TCP ports and negotiated RTP ports in both directions.
Host-network traffic is not isolated by an ordinary pod NetworkPolicy.

## Credentials and activation

1. Use the existing `Reolink` item in the `home-ops` 1Password vault, UUID
   `4udyqvco4rgul7w57whrdho6fy`, field `ONVIF`, for the camera's `admin`
   password. The item's email username is the cloud account, not the camera
   login. External Secrets' Connect provider resolves the item by title.
   Preserve the existing camera account used by Protect. Store the separate
   Scrypted administrator password in 1Password when provisioning the service.
2. The ExternalSecret projects camera fields into `/run/secrets/scrypted`.
   These are operator provisioning inputs, **not automatic plugin configuration**.
   Enter credentials from 1Password into the Scrypted UI over TLS. Scrypted stores
   plugin settings on its PVC. No credentials, pairing codes or exported database
   belong in Git, logs or screenshots. Keep the Scrypted admin password in 1Password.
3. After explicit rollout approval, set `spec.suspend: false` in `ks.yaml` and
   publish through the normal GitOps workflow. Do not apply the parent namespace
   or reconcile Frigate. Verify ExternalSecret Ready, PVC Bound, Deployment Ready,
   route login and direct LAN login. Record the selected node and Frigate UID,
   restart count and recording health before and after.
4. Create the Scrypted administrator immediately over a trusted LAN connection.
   Use `https://scrypted.ironstone.casa` for subsequent administration. Check
   unauthenticated route access is rejected/redirected and direct LAN access
   requires native login. Confirm a Scrypted restart preserves its configuration.
   PVC persistence does not prove backups: take an encrypted Scrypted export
   before plugin upgrades and verify restoration before relying on it for recovery.

## Plugins and exact-model acceptance

Install `@scrypted/reolink`, `@scrypted/onvif` and `@scrypted/homekit` through
Scrypted's plugin UI. Record installed versions. Let their declared dependencies
install normally. There is no assumed multi-plugin environment-variable bootstrap.

First verify Protect recording with its existing settings. Add the camera
directly in the ONVIF plugin on port 8000 and inspect available streams and
events. Revisit the Reolink plugin only if the camera's HTTP service is enabled
in a separately agreed change; do not keep two Scrypted camera imports pulling
duplicate streams. Keep one HomeKit accessory. Do not change camera codecs,
ports or accounts used by Protect without checking the effect on Protect first.

Prefer a native H.264 substream for HomeKit live video and stream copy. Inventory
the actual codecs, resolution, audio, RTSP/RTMP availability and stream limits
on this firmware. Do not infer these from an older Wi-Fi or PoE doorbell.
Reolink's upstream plugin documents ONVIF two-way audio for doorbells generally,
but supplies no evidence for this exact hardware/firmware. Its advice about HTTP
and camera settings also needs checking on this model before making changes.

| Test | Required evidence (currently unverified) |
| --- | --- |
| Identity | Camera reports the exact hardware and firmware above |
| Streams | Scrypted live preview while Protect continues recording without gaps |
| Direct press | Physical button creates a BinarySensor/doorbell event, not merely motion |
| HomeKit | Pair the individual camera accessory; live video and audio on LAN and cellular |
| Notification | Physical press yields one Apple Home notification; opening it plays video |
| Two-way audio | Speech audible in both directions, from LAN and remote; record unsupported if the backchannel fails |
| Recovery | Camera reconnect and Scrypted restart preserve pairing and restore video/events |
| Coexistence | Frigate Birdy and doorbell feeds are healthy after the planned configuration restart; Protect live view and recorded playback still work |

Apple pairing requires the owner's Home app. Do not claim success from a ready pod
or UI preview. HKSV is an additional test if the owner has a suitable hub/iCloud
plan; object detection is not required for live video or button notifications.
Leave Google Home disabled unless separately requested; it gives no assumed
rich phone notification or two-way-talk guarantee.

## Rockchip plugin investigation (2026-10-10)

NPU object detection and VPU video acceleration are separate capabilities.
Neither is enabled by the base deployment.

`@tdalejandro/scrypted-rknn-yolo11` npm version 0.1.0 was published 2026-07-01.
It declares Python 3.10 and dependency `@scrypted/objectdetector`. Its published
integrity is
`sha512-kiXPo55VPQmL3dDD8Sg8HbhsLeHh94EEfV2DrGQ+4E8KD92ShvxUa7H6SZchqsi+LAzDxLpn4/CDaJyJpP65QQ==`.
The current source is **patch-only**, not a standalone package. Main commit
`cc877aceeab6ccf7854c45eb81cd68318a112d4b` converted it on 2026-07-06.
There is one open hardening issue, including runtime pipe deadlock and stale
plugin ZIP/rollback handling. A recent repository push alone does not prove
those fixes are merged or present in the older npm artifact.

The author reports RK3588/Linux ARM64 working on Scrypted 0.143.0, driver 0.9.8,
RKNN toolkit-lite/runtime 2.3.2 and model version 6. The requirements include a
CPython 3.10 ARM64 wheel, `numpy<2`, Pillow 10.3.0, six 1.16.0, Shapely 2.0.4,
pyclipper 1.3.0.post5 and OpenCV headless 4.9.0.80. The bundled YOLO11n model
has static 960x544 input and reference SHA256
`f0ef2a43d4e9bc3ac56b9b2da2d02b60a3826887d624b9924da31539b74feeae`.
The default is four workers; benchmark one worker first if proceeding.
Licensing is not a simple declared SPDX licence; review the upstream model and
runtime terms before redistributing any derived image.

**Selected route: official RKNN 0.1.3 plus the newer community patch**, pinned to
`d122df96539d35adde0635e3f35269fcf8f322f1`. The owner selected the newer patch
on 2026-10-10. This revision is on `claude/etiquetas-coco`, not merged main. It
includes the August hardening fixes and September runtime caching, postprocessing
and COCO-label corrections. Unlike main, its README reports Scrypted 0.147.0
testing. This is upstream-reported compatibility, not cluster validation.
The source, official package, model and runtime pins are in `rknn-patch.lock.json`.

Do not install the stale standalone community npm package or follow a moving
branch during rollout. Do not run the Docker installer against Kubernetes pods
or patch Frigate. Before installation, verify the chosen node's driver,
the runtime ABI, `/proc/device-tree/compatible` and render-device identity, and
test inference in an isolated Scrypted instance with a public/synthetic image.
Back up the Scrypted plugin/database and verify a restore path. Installing the
official `@scrypted/rknn` first is required for this patch route.

The selected revision's nine runtime-file tests and ten postprocessing/label
tests passed locally. A separate runtime-init check drained 200 KB of output
within five seconds without deadlocking. Its Python sources parse, the official npm tarball matches
its SHA512 integrity, and the bundled model matches the SHA256 above. An offline
patched plugin ZIP was built from official 0.1.3 with the same source overlay as
the upstream installer. This verifies packaging, not ARM64 imports or inference.

For Kubernetes installation, preserve official plugin ID `@scrypted/rknn` and
its package metadata. Overlay the pinned source directories and requirements
onto the official `dist/plugin.zip`, rebuilding the ZIP rather than appending
duplicate entries. Upload through Scrypted's authenticated plugin deployment
API (`POST /web/component/script/deploy?npmPackage=@scrypted/rknn`) so its
database stores the patched ZIP; copying extracted Python files alone is not
the installation method. This endpoint was inspected in the Scrypted server
source but has not been exercised against a deployed instance here.
Provision the checksum-verified model into this plugin's own `files/` directory.
The patched requirements select toolkit-lite 2.3.2 rather than official 0.1.3's
2.0.0 beta; verify the Python worker installs the new requirements on restart.
Start with one worker, as set in the deployment. Check the model and runtime
hashes and startup logs before running synthetic inference. Official plugin
updates can overwrite the patch: revalidate the lock before applying one.
Rollback redeploys the saved official ZIP and metadata, restores its dependency
environment and removes only patch-owned model/runtime cache files. Do not
remove a shared system library without checking its other consumers.

`@scrypted/rockchip-essentials` 0.0.3 provides accelerated FFmpeg and depends on
official `@scrypted/rknn`; it uses Python 3.12. Install it only if transcoding
requires VPU acceleration. Its settings give the FFmpeg path: set
`SCRYPTED_FFMPEG_PATH` to that verified persistent path, restart **Scrypted only**,
and select `h264_rkmpp` / `hevc_rkmpp` for the relevant decode/encode operation.
Installing RKNN alone does not accelerate FFmpeg.

Hardware enablement is a separate change after those checks. It needs device
access (DRI render node for NPU; MPP/RGA/DMA heap for VPU), a reviewed container
device-permission solution and stable isolation from Frigate. Do not add broad
privileged mode, `/sys`, USB or a Docker socket just to make it start. The current
cluster has no device plugin providing exclusive allocation. Verify sustained
inference/transcoding and Frigate/Protect health before accepting acceleration.

## HA Visitor fallback (only if direct presses fail)

Confirm that HA's Reolink integration exposes a Visitor binary sensor for this
exact model and that a physical press toggles it. Do not infer the entity ID.
The example blueprint in `examples/visitor-mqtt.yaml` requires selecting that
verified entity. It only publishes a short, non-retained pulse on an `off` to
`on` transition; unknown/unavailable recovery cannot ring the doorbell.

Before enabling the blueprint, extend broker access in a separate reviewed
Mosquitto change: `homeassistant` gets write permission to exactly
`scrypted/doorbell/reolink/visitor`; a new `scrypted` user gets read permission
to exactly that topic. Preserve all existing users, password hashes and ACLs.
Add `scrypted_password` to the existing 1Password `mqtt-auth` item and its
`password_file`, then use that account in Scrypted's MQTT client plugin. Never
reuse Frigate credentials, enable anonymous access, or enable Scrypted's own broker.
Run the existing isolated broker test with new allowed/denied cases before
rolling out that change. Broker rollout must not restart Frigate pods.

Install `@scrypted/mqtt` and `@scrypted/dummy-switch`. Create an MQTT custom
device using `examples/visitor-mqtt.ts` against the established broker. Enable
the camera's **Custom Doorbell Button** extension and select this BinarySensor.
Configure this before HomeKit pairing where possible. Leave the fallback off
when native presses work. Verify one physical press gives one notification,
repeated presses work, and HA startup, broker/Scrypted reconnect and motion alone
do not ring. Clear any retained message on the exact topic before enabling it;
the Scrypted script API does not expose the retained-message flag.

## Local verification

Kustomize builds of the app and home-automation parent passed. YAML lint and
yayamlls source schema checks passed. Helm 4 rendered app-template 5.2.1 with
Gateway API v1 capabilities. Kubeconform validated Deployment, Service and
ServiceAccount; its default catalog skipped HTTPRoute, which yayamlls validated
using the repository's CRD schema catalog. The three repository manifest posture
checks passed (resources, no privilege escalation, no privileged containers).
Cnspec still exited nonzero because discovered Deployment/Service/Namespace
assets do not match that manifest-only policy; this is not a fully clean scan.
The combined yayamlls/flate render check could not find the new uncommitted
HelmRelease in its Git mirror. Run the normal CI gate after publication.
No live application, network, hardware, backup or camera acceptance is implied.

## Sources

- [Official deployment](https://github.com/koush/scrypted/blob/main/install/docker/docker-compose.yml)
- [Reolink plugin](https://github.com/koush/scrypted/blob/main/plugins/reolink/README.md)
- [HomeKit setup](https://docs.scrypted.app/homekit.html)
- [Custom doorbell](https://github.com/koush/scrypted/wiki/Do-It-Yourself-Doorbell-%28Custom-Doorbell-Button%29)
- [Community patch](https://github.com/tdalejandro/scrypted-rknn-yolo11-rk3588)
- [Open hardening issue](https://github.com/tdalejandro/scrypted-rknn-yolo11-rk3588/issues/1)
- [Published community package](https://www.npmjs.com/package/@tdalejandro/scrypted-rknn-yolo11)
- [Official RKNN](https://github.com/koush/scrypted/blob/main/plugins/rknn/README.md)
- [Rockchip Essentials](https://www.npmjs.com/package/@scrypted/rockchip-essentials)
