/*
 * An ED's GUI module for SDL2.
 *
 * Sergei V. Rogachev <rogachevsergei [at] gmail [dot] com>
 *
 * Requires some TTF-font file in the default location stored in the
 * string FONT_FILE.
 */

#include <assert.h>
#include <unistd.h>
#include <fcntl.h>

#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>

#include "unicode.h"
#include "gui.h"

void die(char *);

#define FONT_FILE "default.ttf"
#define FONT_SIZE 18

enum {
	HMargin = 16,
	VMargin = 2,
	Border  = 2,
	Width   = 640,
	Height  = 480,
};

enum ChanSide {
    ChanIn = 0,
    ChanOut
};

typedef enum ChanSide ChanSide;

struct GEventChan {
    int desc[2];
};

typedef struct GEventChan GEventChan, *GEventChanHandle;

static int InputThreadFn(void *ptr);

static GEventChanHandle GEventChanNew(void)
{
    GEventChanHandle chan = calloc(1, sizeof(GEventChan));
    if (chan) {
        if (0 == pipe(chan->desc)) {
            int flags;

            flags = fcntl(chan->desc[ChanIn], F_GETFL, 0);
            fcntl(chan->desc[ChanIn], F_SETFL, flags | O_NONBLOCK);

            flags = fcntl(chan->desc[ChanOut], F_GETFL, 0);
            fcntl(chan->desc[ChanOut], F_SETFL, flags | O_NONBLOCK);
        } else {
            free(chan);
            chan = NULL;
        }
    }

    return chan;
}

static void GEventChanKill(GEventChanHandle chan)
{
    assert(chan);

    if (chan) {
        close(chan->desc[ChanIn]);
        close(chan->desc[ChanOut]);
        free(chan);
    }
}

typedef ssize_t (*GEventChanOpFn)(int fd, void *buf, size_t count);

static int GEventChanOp(GEventChanHandle chan,
                        GEvent          *pEvent,
                        GEventChanOpFn   fn,
                        ChanSide         side)
{
    int rc = -1;

    assert(chan);
    assert(pEvent);
    assert(fn);

    if (chan && pEvent && fn) {
        ssize_t er = fn(chan->desc[side], (void *)pEvent, sizeof(*pEvent));
        if (er == sizeof(*pEvent))
            rc = 0;
    }

    return rc;
}

static ssize_t GEventWriteFn(int fd, void *buf, size_t size)
{
    return write(fd, buf, size);
}

static ssize_t GEventReadFn(int fd, void *buf, size_t size)
{
    return read(fd, buf, size);
}

static int GEventChanGet(GEventChanHandle chan, GEvent *pEvent)
{
    return GEventChanOp(chan, pEvent, GEventReadFn, ChanIn);
}

static int GEventChanPut(GEventChanHandle chan, GEvent *pEvent)
{
    return GEventChanOp(chan, pEvent, GEventWriteFn, ChanOut);
}

struct GSdlContext {
    SDL_Window      *pWindow;
    SDL_Renderer    *pRenderer;
    TTF_Font        *pFont;
    SDL_Thread      *pThread;
    GEventChanHandle chan;

    int width;
    int height;
    int border;

    volatile int needExit;
    int ctrl;
    int move;
};

typedef struct GSdlContext GSdlContext, *GSdlContextHandle;

static GSdlContextHandle globalContext = NULL;

static GSdlContextHandle GSdlContextNew(int width, int height, int border,
                                        const char *font, int fontSize)
{
    GSdlContextHandle cont = calloc(1, sizeof(*cont));

    if (cont) {
        if (0 != SDL_Init(SDL_INIT_EVERYTHING))
            die("cannot init SDL");

        if (0 != TTF_Init())
            die("cannot init font renderer");

        cont->width  = width;
        cont->height = height;
        cont->border = border;

        cont->pWindow = SDL_CreateWindow("ED", SDL_WINDOWPOS_UNDEFINED,
                                         SDL_WINDOWPOS_UNDEFINED,
                                         width, height, SDL_WINDOW_SHOWN);
        if (!cont->pWindow)
            die("cannot create window");

        cont->pRenderer = SDL_CreateRenderer(cont->pWindow, -1,
                                             SDL_RENDERER_ACCELERATED);
        if (!cont->pRenderer)
            die("cannot create renderer");

        cont->pFont = TTF_OpenFont(font, fontSize);
        if (!cont->pFont)
            die("cannot load font file");

        cont->chan = GEventChanNew();
        if (!cont->chan)
            die("cannot create event chan");

        SDL_StartTextInput();

        cont->pThread = SDL_CreateThread(InputThreadFn,
                                         "Input Thread", (void *)cont);
        if (!cont->pThread)
            die("cannot create input thread");
    }

    return cont;
}

static void GSdlContextKill(GSdlContextHandle cont)
{
    assert(cont);

    if (cont) {
        int status;

        cont->needExit = 1;
        SDL_CompilerBarrier();
        SDL_WaitThread(cont->pThread, &status);

        SDL_StopTextInput();

        if (cont->chan)
            GEventChanKill(cont->chan);
        if (cont->pFont)
            TTF_CloseFont(cont->pFont);
        if (cont->pRenderer)
            SDL_DestroyRenderer(cont->pRenderer);
        if (cont->pWindow)
            SDL_DestroyWindow(cont->pWindow);

        free(cont);
    }
}

static void HandleInput(GSdlContextHandle cont)
{
    SDL_Event event;

    assert(cont);

    if (SDL_WaitEventTimeout(&event, 100)) {
        GEvent gev;

        switch (event.type) {
            case SDL_QUIT:
                exit(0);
                break;

            case SDL_TEXTINPUT:
                if (SDL_strlen(event.text.text)) {
                    /* UTF8 invariant check. */
                    assert(SDL_strlen(event.text.text) < 5);

                    gev.type = GKey;
                    utf8_decode_rune(&gev.key,
                                     (unsigned char *)event.text.text,
                                     SDL_strlen(event.text.text));

                    GEventChanPut(cont->chan, &gev);
                }
                break;

            case SDL_WINDOWEVENT:
                gev.type = GResize;
                gev.resize.width = event.window.data1;
                gev.resize.height = event.window.data2;

                GEventChanPut(cont->chan, &gev);
                break;

            case SDL_MOUSEBUTTONUP:
                if (SDL_BUTTON_LEFT == event.button.button)
                    cont->move = 0;
                break;

            case SDL_MOUSEBUTTONDOWN:
                gev.type = GMouseDown;

                switch (event.button.button) {
                    case SDL_BUTTON_LEFT:
                        gev.mouse.button = GBLeft;
                        cont->move = 1;
                        break;
                    case SDL_BUTTON_RIGHT:
                        gev.mouse.button = GBRight;
                        break;
                    case SDL_BUTTON_MIDDLE:
                        gev.mouse.button = GBMiddle;
                        break;
                    /* TODO: handle mouse wheel properly. */
                    case SDL_BUTTON_X1:
                        gev.mouse.button = GBWheelUp;
                        break;
                    case SDL_BUTTON_X2:
                        gev.mouse.button = GBWheelDown;
                        break;
                }
                gev.mouse.x = event.button.x;
                gev.mouse.y = event.button.y;

                GEventChanPut(cont->chan, &gev);
                break;

            case SDL_MOUSEMOTION:
                if (cont->move) {
                    gev.type = GMouseSelect;
                    gev.mouse.button = GBLeft;
                    gev.mouse.x = event.motion.x;
                    gev.mouse.y = event.motion.y;

                    GEventChanPut(cont->chan, &gev);
                }
                break;

            case SDL_KEYUP:
                if (event.key.keysym.sym == SDLK_LCTRL ||
                    event.key.keysym.sym == SDLK_RCTRL) {
                    cont->ctrl = 0;
                }
                break;

            case SDL_KEYDOWN:
                gev.type = GKey;

                switch (event.key.keysym.sym) {
                    case SDLK_ESCAPE:
                        gev.key = GKEsc;

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_F1:
                    case SDLK_F2:
                    case SDLK_F3:
                    case SDLK_F4:
                    case SDLK_F5:
                    case SDLK_F6:
                    case SDLK_F7:
                    case SDLK_F8:
                    case SDLK_F9:
                    case SDLK_F10:
                    case SDLK_F11:
                    case SDLK_F12:
                        gev.key = GKF1 + (event.key.keysym.sym - SDLK_F1);

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_UP:
                        gev.key = GKUp;

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_DOWN:
                        gev.key = GKDown;

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_LEFT:
                        gev.key = GKLeft;

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_RIGHT:
                        gev.key = GKRight;

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_BACKSPACE:
                        gev.key = GKBackspace;

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_PAGEUP:
                        gev.key = GKPageUp;

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_PAGEDOWN:
                        gev.key = GKPageDown;

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_RETURN:
                        gev.key = '\n';

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_TAB:
                        gev.key = '\t';

                        GEventChanPut(cont->chan, &gev);
                        break;

                    case SDLK_LCTRL:
                    case SDLK_RCTRL:
                        cont->ctrl = 1;
                        break;

                    default:
                        /*
                         * Handle non-text keys. If we press some key with
                         * a modifier key, SDL gets two events instead of
                         * one text input event. So, we get LCTRL/RCTRL and
                         * then SDLK_<something>, where <something> is a
                         * letter key.
                         */
                        if (cont->ctrl &&
                            event.key.keysym.sym >= SDLK_a &&
                            event.key.keysym.sym <= SDLK_z) {

                            /* Translate the key code. */
                            gev.key = 1 + event.key.keysym.sym - SDLK_a;
                            GEventChanPut(cont->chan, &gev);
                        }
                }
                break;
        }
    }
}

static int InputThreadFn(void *pArg)
{
    GSdlContextHandle cont = (GSdlContextHandle) pArg;

    assert(cont);

    if (cont) {
        while (1) {
            HandleInput(cont);

            if (cont->needExit)
                break;
        }
    }

    return 0;
}

static int GSdlInit(void)
{
    globalContext = GSdlContextNew(Width, Height, Border, FONT_FILE, FONT_SIZE);
    if (!globalContext)
        die("cannot create global SDL context");

    gui_sdl.actionr.w = HMargin - 3;
    gui_sdl.actionr.h = VMargin + TTF_FontHeight(globalContext->pFont);

    return globalContext->chan->desc[ChanIn];
}

static void GSdlDeinit(void)
{
    assert(globalContext);

    if (globalContext) {
        GSdlContextKill(globalContext);
        SDL_Quit();
    }
}

static void GSdlDrawRect(GRect *clip, int x, int y, int w, int h, GColor c)
{
	SDL_Rect rect;

    assert(globalContext);
    assert(globalContext->pRenderer);

	if (x + w > clip->w)
		w = clip->w - x;
	if (y + h > clip->h)
		h = clip->h - y;

	x += clip->x;
	y += clip->y;

    rect.x = x;
    rect.y = y;
    rect.w = w;
    rect.h = h;

    SDL_SetRenderDrawColor(globalContext->pRenderer,
                           c.red, c.green, c.blue, 255);
    if (c.x)
        SDL_RenderDrawRect(globalContext->pRenderer, &rect);
    else
        SDL_RenderFillRect(globalContext->pRenderer, &rect);
}

static void GSdlDrawCursor(GRect *clip, int insert, int x, int y, int w)
{
    assert(globalContext);
    assert(globalContext->pFont);

    if (insert)
        GSdlDrawRect(clip, x, y, 2,
                     TTF_FontHeight(globalContext->pFont), GXBlack);
    else
        GSdlDrawRect(clip, x, y, w,
                     TTF_FontHeight(globalContext->pFont), GXBlack);
}

static void GSdlGetFont(GFont *ret)
{
    assert(globalContext);
    assert(globalContext->pFont);

    ret->ascent  = TTF_FontAscent(globalContext->pFont);
    ret->descent = -TTF_FontDescent(globalContext->pFont) + 1;
    ret->height  = TTF_FontHeight(globalContext->pFont);
}

static int GSdlTextWidth(Rune *str, int len)
{
    uint16_t *text = calloc(len + 1, sizeof(*text));
    int i, rc, w = 0, h;

    assert(globalContext);
    assert(globalContext->pFont);
    assert(text);

    if (text) {
        /* Convert normal unicode runes to the short ones. */
        for (i = 0; i < len; ++i)
            text[i] = (uint16_t)str[i];

        text[len] = 0;

        rc = TTF_SizeUNICODE(globalContext->pFont, text, &w, &h);
        assert(0 == rc);

        free(text);
    }

    return w;
}

static void GSdlDrawText(GRect *clip, Rune *str,
                         int len, int x, int y, GColor c)
{
    SDL_Color    color = { c.red, c.green, c.blue, 255 };
    SDL_Surface *pSurface;
    SDL_Texture *pTexture;
    SDL_Rect     quad;

    uint16_t *text = calloc(len + 1, sizeof(*text));
    int i;

    assert(globalContext);
    assert(globalContext->pFont);
    assert(globalContext->pRenderer);
    assert(text);

    if (text) {
        /* Convert normal unicode runes to the short ones. */
        for (i = 0; i < len; ++i)
            text[i] = (uint16_t)str[i];

        text[len] = 0;

        x += clip->x;
        y += clip->y;
        y -= TTF_FontAscent(globalContext->pFont);

        /* TODO: do not convert the text twice. */
        if (0 != GSdlTextWidth(str, len)) {
            pSurface = TTF_RenderUNICODE_Blended(globalContext->pFont,
                                                 text, color);
            assert(pSurface);

            if (pSurface) {
                pTexture = SDL_CreateTextureFromSurface(
                                globalContext->pRenderer,
                                pSurface
                           );

                assert(pTexture);

                if (pTexture) {
                    quad.x = x;
                    quad.y = y;
                    quad.w = pSurface->w;
                    quad.h = pSurface->h;

                    SDL_RenderCopy(globalContext->pRenderer, pTexture,
                                   NULL, &quad);

                    SDL_DestroyTexture(pTexture);
                }

                SDL_FreeSurface(pSurface);
            }
        }
        free(text);
    }
}

static int GSdlNextEvent(GEvent *ev)
{
    int er, rc = 0;

    assert(globalContext);
    assert(globalContext->chan);

    er = GEventChanGet(globalContext->chan, ev);
    if (0 == er) {
        if (ev->type == GResize && (!ev->resize.width || !ev->resize.height)) {
            ev->resize.width = Width;
            ev->resize.height = Height;
        }
        rc = 1;
    }

    return rc;
}

static int GSdlSync(void)
{
    assert(globalContext);
    assert(globalContext->pRenderer);

    SDL_RenderPresent(globalContext->pRenderer);

    return 0;
}

static void GSdlSetPointer(GPointer pt)
{
    /* TODO: implement mouse pointers. */
    (void)pt;
}

static void GSdlDecorate(GRect *clip, int dirty, GColor c)
{
    assert(globalContext);
    assert(globalContext->pFont);

    int boxh = VMargin + TTF_FontHeight(globalContext->pFont);
    GSdlDrawRect(clip, HMargin-3, 0, 1, clip->h, c);
    GSdlDrawRect(clip, 0, boxh, HMargin-3, 1, c);
    if (dirty)
        GSdlDrawRect(clip, 2, 2, HMargin-7, boxh-4, c);
}

struct gui gui_sdl = {
    .init       = GSdlInit,
    .fini       = GSdlDeinit,
    .sync       = GSdlSync,
    .decorate   = GSdlDecorate,
    .drawrect   = GSdlDrawRect,
    .drawcursor = GSdlDrawCursor,
    .drawtext   = GSdlDrawText,
    .getfont    = GSdlGetFont,
    .nextevent  = GSdlNextEvent,
    .setpointer = GSdlSetPointer,
    .textwidth  = GSdlTextWidth,
    .hmargin    = HMargin,
    .vmargin    = VMargin,
    .border     = Border,
    .actionr    = {0, 0, 0, 0},
};
