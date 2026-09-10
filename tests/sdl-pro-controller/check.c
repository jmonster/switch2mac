/* Synthetic Pro reports through the actual patched SDL gamepad API and UDP.
 * No physical controller, controller firmware or BLE timing is simulated here. */
#include <SDL3/SDL.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s (%s)\n", __LINE__, #x, SDL_GetError()); exit(2); } } while (0)
static unsigned sequence;
static void put16(unsigned char *p, int value) { p[0] = value & 255; p[1] = (value >> 8) & 255; }
static void put32(unsigned char *p, unsigned value) { for (int i = 0; i < 4; ++i) p[i] = value >> (i * 8); }
static void putfloat(unsigned char *p, float value) { unsigned bits; memcpy(&bits, &value, 4); put32(p, bits); }
static void packet(int fd, const struct sockaddr_in *peer, unsigned buttons, int triggers, int sensors)
{
    unsigned char data[44] = {'S', '2', 'B', '1'};
    put32(data + 4, ++sequence); put32(data + 8, buttons);
    putfloat(data + 12, triggers ? 1 : 0); putfloat(data + 16, triggers ? -1 : 0);
    putfloat(data + 20, triggers ? -1 : 0); putfloat(data + 24, triggers ? 1 : 0);
    data[28] = data[29] = triggers ? 255 : 0;
    if (sensors) {
        put16(data + 32, 32767); put16(data + 34, -16384); put16(data + 36, -32768);
        put16(data + 38, 4096); put16(data + 40, 32767); put16(data + 42, -8192);
    }
    CHECK(sendto(fd, data, sizeof data, 0, (const struct sockaddr *)peer, sizeof *peer) == sizeof data);
}
static void pump(void) { SDL_Delay(10); SDL_UpdateJoysticks(); }
static int sensor_events(void)
{
    int count = 0; SDL_Event event;
    while (SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_EVENT_FIRST, SDL_EVENT_LAST) > 0) {
        if (event.type == SDL_EVENT_GAMEPAD_SENSOR_UPDATE) { CHECK(event.gsensor.sensor_timestamp != 0); ++count; }
    }
    return count;
}
static void rumble_packet(int fd, int strong, int weak)
{
    for (int i = 0; i < 20; ++i) {
        unsigned char data[64]; ssize_t n = recv(fd, data, sizeof data, 0);
        CHECK(n >= 0);
        if (n == 6 && memcmp(data, "S2R1", 4) == 0) {
            CHECK(data[4] == strong && data[5] == weak); return;
        }
    }
    CHECK(!"No rumble packet");
}
static void near_value(float actual, float expected) { CHECK(fabsf(actual - expected) < 0.0001f); }
int main(void)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0); CHECK(fd >= 0);
    struct sockaddr_in server = {0}, peer = {0};
    server.sin_family = AF_INET; server.sin_port = htons(24800);
    server.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(bind(fd, (struct sockaddr *)&server, sizeof server) == 0);
    struct timeval timeout = {2, 0};
    CHECK(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout) == 0);
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    CHECK(SDL_Init(SDL_INIT_GAMEPAD));
    SDL_SetGamepadEventsEnabled(true);
    unsigned char hello[64]; socklen_t size = sizeof peer;
    CHECK(recvfrom(fd, hello, sizeof hello, 0, (struct sockaddr *)&peer, &size) >= 0);
    SDL_JoystickID *ids = NULL; int count = 0; Uint64 deadline = SDL_GetTicks() + 1500;
    do {
        packet(fd, &peer, 0, 0, 0); pump(); SDL_free(ids); ids = SDL_GetGamepads(&count);
    } while (!count && SDL_GetTicks() < deadline);
    CHECK(count == 1 && ids); SDL_JoystickID id = ids[0]; SDL_free(ids);
    SDL_Gamepad *pad = SDL_OpenGamepad(id); CHECK(pad);
    SDL_Joystick *joy = SDL_GetGamepadJoystick(pad); CHECK(joy);
    CHECK(SDL_GetBooleanProperty(SDL_GetJoystickProperties(joy), SDL_PROP_JOYSTICK_CAP_RUMBLE_BOOLEAN, false));
    CHECK(SDL_GamepadHasSensor(pad, SDL_SENSOR_GYRO) && SDL_GamepadHasSensor(pad, SDL_SENSOR_ACCEL));
    CHECK(!SDL_GamepadSensorEnabled(pad, SDL_SENSOR_GYRO));
    CHECK(SDL_GetGamepadSensorDataRate(pad, SDL_SENSOR_GYRO) == 0); // unknown BLE cadence

    // Every physical non-trigger button reaches its stable joystick slot.
    const unsigned bits[] = {4,8,1,2,0x100,0x1000,0x200,0x800,0x400,0x400000,0x40,
        0x20000,0x10000,0x80000,0x40000,0x2000,0x1000000,0x2000000,0x4000};
    for (int b = 0; b < 19; ++b) {
        packet(fd, &peer, bits[b], 0, 0); pump();
        for (int j = 0; j < 19; ++j) CHECK(SDL_GetJoystickButton(joy, j) == (j == b));
        packet(fd, &peer, 0, 0, 0); pump(); CHECK(!SDL_GetJoystickButton(joy, b));
    }
    packet(fd, &peer, 0x3004000, 1, 0); pump();
    CHECK(SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_LEFT_PADDLE1));
    CHECK(SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1));
    CHECK(SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_MISC2));
    for (int axis = 0; axis < 6; ++axis) {
        int expected = axis == 2 || axis == 3 ? -32767 : 32767;
        CHECK(SDL_GetJoystickAxis(joy, axis) == expected);
    }
    packet(fd, &peer, 0, 0, 0); pump();
    CHECK(SDL_GetJoystickAxis(joy, 4) == -32768 && SDL_GetJoystickAxis(joy, 5) == -32768);
    puts("PASS SDL Pro 21 controls, both sticks, digital triggers and GL/GR/C gamepad mapping");

    // Sensors are opt-in; polling cached state must not invent new samples.
    sensor_events(); packet(fd, &peer, 0, 0, 1); pump(); CHECK(sensor_events() == 0);
    CHECK(SDL_SetGamepadSensorEnabled(pad, SDL_SENSOR_GYRO, true));
    CHECK(SDL_SetGamepadSensorEnabled(pad, SDL_SENSOR_ACCEL, true));
    packet(fd, &peer, 0, 0, 1); pump(); CHECK(sensor_events() == 2);
    float gyro[3], accel[3];
    CHECK(SDL_GetGamepadSensorData(pad, SDL_SENSOR_GYRO, gyro, 3));
    CHECK(SDL_GetGamepadSensorData(pad, SDL_SENSOR_ACCEL, accel, 3));
    near_value(gyro[0], 34.8f); near_value(gyro[1], -32768.0f * 34.8f / 32767.0f);
    near_value(gyro[2], 16384.0f * 34.8f / 32767.0f);
    near_value(accel[0], 4096.0f * 9.80665f * 8.0f / 32767.0f);
    near_value(accel[1], -8192.0f * 9.80665f * 8.0f / 32767.0f);
    near_value(accel[2], -9.80665f * 8.0f);
    pump(); CHECK(sensor_events() == 0);
    packet(fd, &peer, 0, 0, 0); packet(fd, &peer, 0, 0, 1); pump();
    CHECK(sensor_events() == 4); // preserve both queued IMU reports
    CHECK(SDL_SetGamepadSensorEnabled(pad, SDL_SENSOR_GYRO, false));
    packet(fd, &peer, 0, 0, 0); pump(); CHECK(sensor_events() == 1);
    CHECK(SDL_SetGamepadSensorEnabled(pad, SDL_SENSOR_ACCEL, false));
    packet(fd, &peer, 0, 0, 1); pump(); CHECK(sensor_events() == 0);
    puts("PASS SDL Pro sensor units, axes, opt-in, queued samples and no poll duplicates");

    CHECK(SDL_RumbleGamepad(pad, 65535, 0, 1000)); rumble_packet(fd, 255, 0);
    CHECK(SDL_RumbleGamepad(pad, 0, 65535, 1000)); rumble_packet(fd, 0, 255);
    SDL_CloseGamepad(pad); rumble_packet(fd, 0, 0);
    pad = SDL_OpenGamepad(id); CHECK(pad);
    CHECK(!SDL_GamepadSensorEnabled(pad, SDL_SENSOR_GYRO));
    CHECK(!SDL_GamepadSensorEnabled(pad, SDL_SENSOR_ACCEL));
    sensor_events(); packet(fd, &peer, 0, 0, 1); pump(); CHECK(sensor_events() == 0);
    SDL_CloseGamepad(pad); SDL_Quit(); close(fd);
    puts("PASS SDL Pro independent rumble channels, close stop and fresh reopen state");
    return 0;
}
