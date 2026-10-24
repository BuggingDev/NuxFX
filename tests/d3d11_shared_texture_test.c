// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NuxFX contributors
// Two D3D11 devices share a texture through an NT handle, with and without a keyed mutex.
// Device A clears the texture, device B opens it with ID3D11Device1::OpenSharedResource1,
// reads it back and compares the colour. This is the call pattern After Effects uses for
// the tiles of the Advanced 3D renderer. Build and run with
// tests/run_d3d11_shared_texture_test.sh.
//
// Exit codes: 0 pass, 1 setup failed, 10 OpenSharedResource1 returned an error,
// 11 the second device read the wrong colour. A crash (an exception escaping
// OpenSharedResource1) ends the process with another status ("terminate called" gives 3).
#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPECT_R 255
#define EXPECT_G 128
#define EXPECT_B 64

static int make_device(const char *name, ID3D11Device **dev, ID3D11DeviceContext **ctx) {
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &level, 1,
                                   D3D11_SDK_VERSION, dev, NULL, ctx);
    printf("device %s hr=0x%08lx\n", name, (unsigned long)hr);
    fflush(stdout);
    return SUCCEEDED(hr);
}

int main(int argc, char **argv) {
    int keyed = argc > 1 && !strcmp(argv[1], "keyed");
    ID3D11Device *devA = NULL, *devB = NULL;
    ID3D11DeviceContext *ctxA = NULL, *ctxB = NULL;
    printf("mode %s\n", keyed ? "keyed mutex" : "plain");
    if (!make_device("A", &devA, &ctxA) || !make_device("B", &devB, &ctxB))
        return 1;

    D3D11_TEXTURE2D_DESC td;
    memset(&td, 0, sizeof(td));
    td.Width = 64;
    td.Height = 64;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    td.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE |
                   (keyed ? D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX : D3D11_RESOURCE_MISC_SHARED);

    ID3D11Texture2D *texA = NULL;
    HRESULT hr = devA->lpVtbl->CreateTexture2D(devA, &td, NULL, &texA);
    printf("create shared texture hr=0x%08lx\n", (unsigned long)hr);
    fflush(stdout);
    if (FAILED(hr))
        return 1;

    IDXGIResource1 *res1 = NULL;
    hr = texA->lpVtbl->QueryInterface(texA, &IID_IDXGIResource1, (void **)&res1);
    if (FAILED(hr))
        return 1;
    HANDLE handle = NULL;
    hr = res1->lpVtbl->CreateSharedHandle(res1, NULL,
                                          DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
                                          NULL, &handle);
    printf("CreateSharedHandle hr=0x%08lx handle=%p\n", (unsigned long)hr, handle);
    fflush(stdout);
    if (FAILED(hr))
        return 1;

    ID3D11Device1 *devB1 = NULL;
    hr = devB->lpVtbl->QueryInterface(devB, &IID_ID3D11Device1, (void **)&devB1);
    if (FAILED(hr))
        return 1;
    printf("calling OpenSharedResource1\n");
    fflush(stdout);
    ID3D11Texture2D *texB = NULL;
    hr = devB1->lpVtbl->OpenSharedResource1(devB1, handle, &IID_ID3D11Texture2D, (void **)&texB);
    printf("OpenSharedResource1 hr=0x%08lx\n", (unsigned long)hr);
    fflush(stdout);
    if (FAILED(hr) || !texB)
        return 10;

    IDXGIKeyedMutex *mtxA = NULL, *mtxB = NULL;
    if (keyed) {
        texA->lpVtbl->QueryInterface(texA, &IID_IDXGIKeyedMutex, (void **)&mtxA);
        texB->lpVtbl->QueryInterface(texB, &IID_IDXGIKeyedMutex, (void **)&mtxB);
        printf("keyed mutex interfaces A=%p B=%p\n", (void *)mtxA, (void *)mtxB);
        fflush(stdout);
        if (!mtxA || !mtxB)
            return 1;
        hr = mtxA->lpVtbl->AcquireSync(mtxA, 0, 5000);
        printf("A AcquireSync(0) hr=0x%08lx\n", (unsigned long)hr);
        fflush(stdout);
    }

    /* UpdateSubresource is a real copy command. A ClearRenderTargetView alone would not do: DXVK
     * keeps a clear back until something else uses the image on that device. */
    static unsigned char pixels[64 * 64 * 4];
    for (int i = 0; i < 64 * 64; i++) {
        pixels[i * 4 + 0] = EXPECT_R;
        pixels[i * 4 + 1] = EXPECT_G;
        pixels[i * 4 + 2] = EXPECT_B;
        pixels[i * 4 + 3] = 255;
    }
    ctxA->lpVtbl->UpdateSubresource(ctxA, (ID3D11Resource *)texA, 0, NULL, pixels, 64 * 4, 0);
    if (getenv("SHARED_TEST_READBACK_A")) {
        /* A read back on A forces the clear to run (DXVK may defer it until the image is used). */
        D3D11_TEXTURE2D_DESC rd = td;
        rd.Usage = D3D11_USAGE_STAGING;
        rd.BindFlags = 0;
        rd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        rd.MiscFlags = 0;
        ID3D11Texture2D *stA = NULL;
        devA->lpVtbl->CreateTexture2D(devA, &rd, NULL, &stA);
        ctxA->lpVtbl->CopyResource(ctxA, (ID3D11Resource *)stA, (ID3D11Resource *)texA);
        D3D11_MAPPED_SUBRESOURCE mA;
        memset(&mA, 0, sizeof(mA));
        if (SUCCEEDED(ctxA->lpVtbl->Map(ctxA, (ID3D11Resource *)stA, 0, D3D11_MAP_READ, 0, &mA))) {
            const unsigned char *pa = (const unsigned char *)mA.pData;
            printf("A reads pixel (%u, %u, %u, %u)\n", pa[0], pa[1], pa[2], pa[3]);
            ctxA->lpVtbl->Unmap(ctxA, (ID3D11Resource *)stA, 0);
        }
    }
    if (keyed) {
        hr = mtxA->lpVtbl->ReleaseSync(mtxA, 1);
        printf("A ReleaseSync(1) hr=0x%08lx\n", (unsigned long)hr);
        fflush(stdout);
    }
    ctxA->lpVtbl->Flush(ctxA);
    Sleep(300);

    if (keyed) {
        hr = mtxB->lpVtbl->AcquireSync(mtxB, 1, 5000);
        printf("B AcquireSync(1) hr=0x%08lx\n", (unsigned long)hr);
        fflush(stdout);
    }
    D3D11_TEXTURE2D_DESC sd = td;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.BindFlags = 0;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    sd.MiscFlags = 0;
    ID3D11Texture2D *staging = NULL;
    hr = devB->lpVtbl->CreateTexture2D(devB, &sd, NULL, &staging);
    if (FAILED(hr))
        return 1;
    ctxB->lpVtbl->CopyResource(ctxB, (ID3D11Resource *)staging, (ID3D11Resource *)texB);
    D3D11_MAPPED_SUBRESOURCE map;
    memset(&map, 0, sizeof(map));
    hr = ctxB->lpVtbl->Map(ctxB, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
    if (FAILED(hr))
        return 1;
    const unsigned char *px = (const unsigned char *)map.pData;
    printf("B reads pixel (%u, %u, %u, %u), expected (%d, %d, %d, 255)\n", px[0], px[1], px[2], px[3],
           EXPECT_R, EXPECT_G, EXPECT_B);
    /* 0.5 and 0.25 convert to 127/128 and 63/64 depending on the rounding of the GPU. */
    int ok = px[0] == EXPECT_R && abs((int)px[1] - EXPECT_G) <= 1 && abs((int)px[2] - EXPECT_B) <= 1 && px[3] == 255;
    ctxB->lpVtbl->Unmap(ctxB, (ID3D11Resource *)staging, 0);
    if (keyed)
        mtxB->lpVtbl->ReleaseSync(mtxB, 0);
    printf(ok ? "RESULT pass\n" : "RESULT wrong colour\n");
    fflush(stdout);
    return ok ? 0 : 11;
}
