// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NuxFX contributors
// Regression check for the dzn VIEWPORT_WITH_COUNT / SCISSOR_WITH_COUNT fix (patch 17).
// A D3D11 DXGI swapchain window must show the backbuffer colour (red) after Present.
// Build and run with tests/run_dxgi_present_test.sh.
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }

int WINAPI WinMain(HINSTANCE hi, HINSTANCE hp, LPSTR cmd, int show) {
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = WndProc; wc.hInstance = hi; wc.lpszClassName = "dxgi_present_test";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("dxgi_present_test", "dxgi_present_test", WS_OVERLAPPEDWINDOW,
                              100, 100, 400, 300, NULL, NULL, hi, NULL);
    ShowWindow(hwnd, SW_SHOW); UpdateWindow(hwnd);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    RECT cr = {0};
    GetClientRect(hwnd, &cr);
    sd.BufferCount = 2;
    sd.BufferDesc.Width = cr.right - cr.left; sd.BufferDesc.Height = cr.bottom - cr.top;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd; sd.SampleDesc.Count = 1; sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain *sc = NULL; ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev, NULL, &ctx);
    printf("create hr=0x%08lx\n", (unsigned long)hr); fflush(stdout);
    if (FAILED(hr)) return 1;

    ID3D11Texture2D *bb = NULL;
    sc->lpVtbl->GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void**)&bb);
    ID3D11RenderTargetView *rtv = NULL;
    dev->lpVtbl->CreateRenderTargetView(dev, (ID3D11Resource*)bb, NULL, &rtv);

    float red[4] = {1.0f, 0.0f, 0.0f, 1.0f};
    for (int i = 0; i < 240; i++) {
        MSG msg; while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        ctx->lpVtbl->OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ctx->lpVtbl->ClearRenderTargetView(ctx, rtv, red);
        /* A staging copy of the backbuffer at frame 5 is required: without it this
           test presents black even with the dzn fix (docs/known-issues.md). */
        if (i == 5) {
            D3D11_TEXTURE2D_DESC td = {0};
            bb->lpVtbl->GetDesc(bb, &td);
            D3D11_TEXTURE2D_DESC sd2 = td; sd2.Usage = D3D11_USAGE_STAGING; sd2.BindFlags = 0; sd2.CPUAccessFlags = D3D11_CPU_ACCESS_READ; sd2.MiscFlags = 0;
            ID3D11Texture2D *stg = NULL; dev->lpVtbl->CreateTexture2D(dev, &sd2, NULL, &stg);
            ctx->lpVtbl->CopyResource(ctx, (ID3D11Resource*)stg, (ID3D11Resource*)bb);
            D3D11_MAPPED_SUBRESOURCE mp = {0};
            if (SUCCEEDED(ctx->lpVtbl->Map(ctx, (ID3D11Resource*)stg, 0, D3D11_MAP_READ, 0, &mp))) ctx->lpVtbl->Unmap(ctx, (ID3D11Resource*)stg, 0);
        }
        hr = sc->lpVtbl->Present(sc, 1, 0);
        if (FAILED(hr)) { printf("present %d hr=0x%08lx\n", i, (unsigned long)hr); fflush(stdout); break; }
        Sleep(16);
    }
    printf("frames done\n"); fflush(stdout);
    Sleep(4000);
    return 0;
}