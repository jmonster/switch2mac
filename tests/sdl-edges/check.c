/* Synthetic loopback traffic through the real patched SDL, no radio or GUI. */
#include <SDL3/SDL.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s (%s)\n", __LINE__, #x, SDL_GetError()); exit(2); } } while (0)

static void packet(int fd, const struct sockaddr_in *to, unsigned buttons,
                   unsigned char trigger)
{
    unsigned char data[44] = {'S', '2', 'B', '1'};
    for (int i = 0; i < 4; ++i) data[8 + i] = (unsigned char)(buttons >> (8 * i));
    data[28] = trigger;
    CHECK(sendto(fd, data, sizeof data, 0, (const struct sockaddr *)to, sizeof *to) == sizeof data);
}

static void drain_events(void)
{
    SDL_Event event;
    while (SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_EVENT_FIRST, SDL_EVENT_LAST) > 0) {}
}

int main(void)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(fd >= 0);
    struct sockaddr_in server = {0}, peer = {0};
    server.sin_family = AF_INET;
    server.sin_port = htons(24800);
    server.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(bind(fd, (struct sockaddr *)&server, sizeof server) == 0);
    struct timeval timeout = {2, 0};
    CHECK(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout) == 0);
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    CHECK(SDL_Init(SDL_INIT_JOYSTICK));
    SDL_SetJoystickEventsEnabled(true);
    unsigned char hello[64];
    socklen_t size = sizeof peer;
    CHECK(recvfrom(fd, hello, sizeof hello, 0, (struct sockaddr *)&peer, &size) >= 0);
    int count = 0;
    SDL_JoystickID *ids = NULL;
    // SDL throttles device discovery independently of packet delivery.
    // Wait for registration, not for the input edges tested below.
    Uint64 deadline = SDL_GetTicks() + 1500;
    do {
        packet(fd, &peer, 0, 0);
        SDL_Delay(10);
        SDL_UpdateJoysticks();
        SDL_free(ids);
        ids = SDL_GetJoysticks(&count);
    } while (count == 0 && SDL_GetTicks() < deadline);
    CHECK(count == 1 && ids);
    SDL_Joystick *joy = SDL_OpenJoystick(ids[0]);
    SDL_JoystickID id = ids[0];
    SDL_free(ids);
    CHECK(joy);
    // Establish both resting axis value and real activity before the edge
    // test; SDL suppresses initial analog jitter until an axis first moves.
    packet(fd, &peer, 8, 128);
    SDL_Delay(10); SDL_UpdateJoysticks();
    CHECK(SDL_GetJoystickButton(joy, 1));
    packet(fd, &peer, 0, 0);
    SDL_Delay(10); SDL_UpdateJoysticks();
    CHECK(!SDL_GetJoystickButton(joy, 1));
    drain_events();

    // A complete tap and a full trigger excursion queued before one update.
    packet(fd, &peer, 8, 255);   // Nintendo A -> existing joystick button 1
    packet(fd, &peer, 0, 0);
    SDL_Delay(10); SDL_UpdateJoysticks();
    int downs = 0, ups = 0, trigger_down = 0, trigger_up = 0;
    SDL_Event event;
    while (SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_EVENT_FIRST, SDL_EVENT_LAST) > 0) {
        if (event.type == SDL_EVENT_JOYSTICK_BUTTON_DOWN && event.jbutton.which == id && event.jbutton.button == 1) {
            CHECK(ups == 0); ++downs;
        }
        if (event.type == SDL_EVENT_JOYSTICK_BUTTON_UP && event.jbutton.which == id && event.jbutton.button == 1) {
            CHECK(downs == 1); ++ups;
        }
        if (event.type == SDL_EVENT_JOYSTICK_AXIS_MOTION && event.jaxis.which == id && event.jaxis.axis == 4) {
            if (event.jaxis.value == SDL_JOYSTICK_AXIS_MAX) ++trigger_down;
            if (event.jaxis.value == SDL_JOYSTICK_AXIS_MIN) ++trigger_up;
        }
    }
    if (downs != 1 || ups != 1 || trigger_down != 1 || trigger_up != 1) {
        fprintf(stderr, "Lost queued transitions: A=%d/%d trigger=%d/%d\n", downs, ups, trigger_down, trigger_up);
        SDL_CloseJoystick(joy); SDL_Quit(); close(fd);
        return 42;  // Expected only for the explicit baseline negative control.
    }
    CHECK(!SDL_GetJoystickButton(joy, 1));
    CHECK(SDL_GetJoystickAxis(joy, 4) == SDL_JOYSTICK_AXIS_MIN);

    // Two taps in one pump, including a simultaneous shoulder button.
    packet(fd, &peer, 8 | 0x400000, 0); packet(fd, &peer, 0, 0);
    packet(fd, &peer, 8, 0); packet(fd, &peer, 0, 0);
    SDL_Delay(10); SDL_UpdateJoysticks();
    downs = ups = 0;
    while (SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_EVENT_FIRST, SDL_EVENT_LAST) > 0) {
        if (event.type == SDL_EVENT_JOYSTICK_BUTTON_DOWN && event.jbutton.button == 1) ++downs;
        if (event.type == SDL_EVENT_JOYSTICK_BUTTON_UP && event.jbutton.button == 1) ++ups;
    }
    CHECK(downs == 2 && ups == 2);

    // Close/reopen must not leave a dangling pointer used by packet delivery.
    SDL_CloseJoystick(joy);
    packet(fd, &peer, 8, 0); SDL_Delay(10); SDL_UpdateJoysticks();
    joy = SDL_OpenJoystick(id); CHECK(joy);
    SDL_UpdateJoysticks();
    CHECK(SDL_GetJoystickButton(joy, 1));
    packet(fd, &peer, 0, 0); SDL_Delay(10); SDL_UpdateJoysticks();
    CHECK(!SDL_GetJoystickButton(joy, 1));
    SDL_CloseJoystick(joy); SDL_Quit(); close(fd);
    puts("SDL queued-edge, analog-trigger and reopen regressions passed.");
    return 0;
}
