// Paste into a Scrypted MQTT custom device. Globals are supplied by Scrypted.
// Use only non-retained messages; clear retained state before enabling this.
device.binaryState = false;
let reset: ReturnType<typeof setTimeout> | undefined;
mqtt.subscribe({
    'scrypted/doorbell/reolink/visitor': value => {
        if (value.text !== 'ON' && value.text !== 'OFF')
            return;
        if (reset)
            clearTimeout(reset);
        device.binaryState = value.text === 'ON';
        // Reset even if HA stops before publishing OFF.
        if (device.binaryState)
            reset = setTimeout(() => device.binaryState = false, 1000);
    },
});
mqtt.handleTypes(ScryptedInterface.BinarySensor);
