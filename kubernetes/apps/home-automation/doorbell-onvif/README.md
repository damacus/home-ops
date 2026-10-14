# Doorbell relay

The Reolink at 192.168.1.17 feeds Scrypted once using its 720p H.264 substream.
Frigate and the ONVIF bridge consume the same Scrypted rebroadcast. Home Assistant
uses native Reolink visitor events and the Frigate camera entity `camera.doorbell`.
Native Reolink camera entities remain disabled to avoid additional video sessions.

## Persistent settings

- Scrypted camera 29: all stream choices use `Profile001_SubStream` and the
  rebroadcast port is 10454. Restart Scrypted after changing the port.
- Scrypted PVC retains the random rebroadcast path. `scrypted-doorbell-relay` is
  encrypted with SOPS in the Scrypted application and contains the Frigate URL
  and bridge configuration. Regenerate both values if the camera is recreated.
- The bridge runs on node-0b06df, using its existing wired MAC 00:e0:4c:0b:06:df
  and address 192.168.1.27. ONVIF listens on 18081; the RTSP proxy listens on
  18554. UUID f240fd7d-648e-4bf6-baa2-afb3e7a72528 must remain stable.
- It runs without NET_ADMIN or root and cannot create a macvlan. A node/interface
  replacement requires an explicit configuration update.
- The bridge has no ONVIF authentication. Keep these ports on the trusted LAN;
  do not publish them through the ingress gateway. The snapshot fallback provided
  by the bridge is static; Home Assistant pictures come from Frigate instead.

## Protect migration

Adopt `FrontDoorRelay` as a new camera. Keep the original Reolink camera entry
and its recordings. Disable its direct connection using a non-destructive
Protect setting; do not unadopt/delete it or use any option that erases history.
Verify live video and a new recording on the relay before ending the cutover.

## Phone alerts

The Home Assistant package is mounted from `home-assistant-doorbell` and sends
native visitor presses to `notify.mobile_app_pixel_9_pro`. Laura’s notifications
were tested successfully and then disabled at the owner’s request. Pictures use the authenticated camera proxy; View
live opens the camera more-info panel. Each phone is dispatched independently.

Android uses high-priority, zero-TTL delivery and the alarm_stream channel.
Enable pop-on-screen and the required DND exception on the Pixel. iOS requests a
critical sound when enabled; Laura must allow Critical Alerts for Home Assistant. These phone
permissions and actual delivery require physical-device testing.

Run `script.doorbell_phone_alert` with a labelled `message` for a delivery test,
then press the physical bell to verify the native trigger. Test with phones
locked and silenced. Confirm pictures and View live on the enabled recipient devices.

## Verification and rollback

Check Frigate `/api/stats` for doorbell camera/process FPS and fresh snapshots.
Inspect established camera RTSP connections on the Scrypted node; only Scrypted
should pull video directly. Native Home Assistant event traffic is expected.
Do not interpret an HTTP 200 snapshot alone as proof of fresh video.

To roll back video routing, restore the previous Frigate input and its original
ExternalSecret together. Retain both Protect entries and all recording volumes.
Do not enable multiple direct camera consumers during diagnosis.
