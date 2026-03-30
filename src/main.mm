#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>

#include "app.h"
#include "ui/ui.h"

#include <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3native.h>

#include <imgui.h>
#include <imgui_impl_glfw.h>
#include <imgui_impl_metal.h>

#include <cstdio>
#include <chrono>

// Globals for callbacks
static App* g_app = nullptr;
static bool g_mouseDown = false;
static bool g_rightMouseDown = false;
static double g_lastMouseX = 0, g_lastMouseY = 0;

// GLFW scroll = two-finger scroll on trackpad = PAN
static void scrollCallback(GLFWwindow* window, double xoff, double yoff) {
    if (ImGui::GetIO().WantCaptureMouse) return;
    if (g_app) g_app->onScroll(xoff, yoff);
}

static void framebufferSizeCallback(GLFWwindow* window, int width, int height) {
    if (g_app && width > 0 && height > 0) {
        g_app->onResize(width, height);
    }
}

int main(int argc, char** argv) {
    @autoreleasepool {
        setlinebuf(stdout);  // line-buffer stdout so printf shows immediately
        printf("=== CURSDAR2 - Metal Radar Workstation ===\n");
        printf("Loading next-generation shell on the Metal radar engine\n\n");

        // GLFW init
        if (!glfwInit()) {
            fprintf(stderr, "Failed to initialize GLFW\n");
            return 1;
        }

        // No OpenGL - we're using Metal
        glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
        glfwWindowHint(GLFW_MAXIMIZED, GLFW_TRUE);

        GLFWmonitor* monitor = glfwGetPrimaryMonitor();
        const GLFWvidmode* mode = glfwGetVideoMode(monitor);
        int winW = mode->width;
        int winH = mode->height;

        GLFWwindow* window = glfwCreateWindow(winW, winH, "CURSDAR2", nullptr, nullptr);
        if (!window) {
            fprintf(stderr, "Failed to create window\n");
            glfwTerminate();
            return 1;
        }

        glfwSetScrollCallback(window, scrollCallback);
        glfwSetFramebufferSizeCallback(window, framebufferSizeCallback);

        // Create Metal device and layer
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> commandQueue = [device newCommandQueue];

        // Set up CAMetalLayer on the GLFW window
        NSWindow* nsWindow = glfwGetCocoaWindow(window);
        CAMetalLayer* metalLayer = [CAMetalLayer layer];
        metalLayer.device = device;
        metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metalLayer.framebufferOnly = YES;

        // Get the content view and set its layer
        NSView* contentView = [nsWindow contentView];
        [contentView setWantsLayer:YES];
        [contentView setLayer:metalLayer];

        // ── Native macOS gesture support ────────────────────────
        // Monitor pinch-to-zoom (magnification) events globally.
        // GLFW doesn't expose these, so we tap into NSEvent directly.
        id magnifyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMagnify
            handler:^NSEvent* _Nullable(NSEvent* event) {
                if (g_app && !ImGui::GetIO().WantCaptureMouse) {
                    g_app->onMagnify(event.magnification);
                }
                return event;
            }];

        // Smart zoom (two-finger double-tap) — toggle between zoomed-in and CONUS view
        id smartZoomMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskSmartMagnify
            handler:^NSEvent* _Nullable(NSEvent* event) {
                if (g_app && !ImGui::GetIO().WantCaptureMouse) {
                    // Toggle between zoomed-in (180) and CONUS (28)
                    auto& vp = g_app->viewport();
                    if (vp.zoom > 80.0) {
                        vp.zoom = 28.0;  // zoom out to CONUS
                    } else {
                        vp.zoom = 180.0; // zoom in to station
                    }
                }
                return event;
            }];

        // Get actual framebuffer size
        glfwGetFramebufferSize(window, &winW, &winH);
        metalLayer.drawableSize = CGSizeMake(winW, winH);

        // Dear ImGui init
        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO& io = ImGui::GetIO();
        io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
        io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;

        ImGui_ImplGlfw_InitForOther(window, true);
        ImGui_ImplMetal_Init(device);

        ui::init();

        int exitCode = 0;

        // App init
        {
            App app;
            g_app = &app;

            if (!app.init(winW, winH)) {
                fprintf(stderr, "Failed to initialize app\n");
                g_app = nullptr;
                exitCode = 1;
            } else {
                printf("Starting main loop...\n");

                auto lastFrame = std::chrono::steady_clock::now();
                int frameCount = 0;
                float fpsTimer = 0;
                float fps = 0;

                while (!glfwWindowShouldClose(window)) {
                    @autoreleasepool {
                        glfwPollEvents();

                        auto now = std::chrono::steady_clock::now();
                        float dt = std::chrono::duration<float>(now - lastFrame).count();
                        lastFrame = now;

                        frameCount++;
                        fpsTimer += dt;
                        if (fpsTimer >= 1.0f) {
                            fps = frameCount / fpsTimer;
                            frameCount = 0;
                            fpsTimer = 0;
                            std::string activeStation = app.activeStationName();
                            char title[144];
                            snprintf(title, sizeof(title),
                                     "CURSDAR2 - %s | %s | Tilt %.1f | %d stations | %.0f FPS",
                                     activeStation.c_str(),
                                     PRODUCT_INFO[app.activeProduct()].name,
                                     app.activeTiltAngle(),
                                     app.stationsLoaded(), fps);
                            glfwSetWindowTitle(window, title);
                        }

                        // Mouse tracking
                        double mx, my;
                        glfwGetCursorPos(window, &mx, &my);

                        if (!ImGui::GetIO().WantCaptureMouse && !app.crossSection() && !app.mode3D()) {
                            app.onMouseMove(mx, my);
                        }

                        if (!ImGui::GetIO().WantCaptureMouse) {
                            if (glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_LEFT) == GLFW_PRESS) {
                                if (g_mouseDown)
                                    app.onMouseDrag(mx - g_lastMouseX, my - g_lastMouseY);
                                g_mouseDown = true;
                            } else {
                                g_mouseDown = false;
                            }
                            if (glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS) {
                                if (g_rightMouseDown)
                                    app.onRightDrag(mx - g_lastMouseX, my - g_lastMouseY);
                                else if (app.crossSection())
                                    app.onMiddleClick(mx, my);
                                g_rightMouseDown = true;
                            } else {
                                g_rightMouseDown = false;
                            }
                            if (g_rightMouseDown && app.crossSection()) {
                                app.onMiddleDrag(mx, my);
                            }
                        }
                        g_lastMouseX = mx;
                        g_lastMouseY = my;

                        app.update(dt);
                        app.render();

                        // Metal rendering frame
                        id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
                        if (!drawable) continue;

                        MTLRenderPassDescriptor* renderPassDesc = [MTLRenderPassDescriptor new];
                        renderPassDesc.colorAttachments[0].texture = drawable.texture;
                        renderPassDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
                        renderPassDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
                        renderPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.07, 1.0);

                        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

                        // ImGui Metal frame
                        ImGui_ImplMetal_NewFrame(renderPassDesc);
                        ImGui_ImplGlfw_NewFrame();
                        ImGui::NewFrame();

                        ui::render(app);

                        // FPS overlay
                        ImGui::SetNextWindowPos(ImVec2((float)app.viewport().width - 100,
                                                        (float)app.viewport().height - 30));
                        ImGui::Begin("##fps", nullptr,
                                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                                     ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                                     ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoBackground);
                        ImGui::TextColored(ImVec4(0.5f, 1.0f, 0.5f, 0.8f), "%.0f FPS", fps);
                        ImGui::End();

                        ImGui::Render();

                        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDesc];
                        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, encoder);
                        [encoder endEncoding];

                        [commandBuffer presentDrawable:drawable];
                        [commandBuffer commit];
                    }
                }

                // Clear global pointer and remove gesture monitors BEFORE App destructs
                // (prevents callbacks from accessing destroyed state)
                g_app = nullptr;

                [NSEvent removeMonitor:magnifyMonitor];
                [NSEvent removeMonitor:smartZoomMonitor];
                magnifyMonitor = nil;
                smartZoomMonitor = nil;
            }
            // App destructor runs here — downloads stopped, GPU flushed, then Metal objects released
        }

        ImGui_ImplMetal_Shutdown();
        ImGui_ImplGlfw_Shutdown();
        ImGui::DestroyContext();

        glfwDestroyWindow(window);
        glfwTerminate();

        printf("macdar shutdown complete.\n");
        return exitCode;
    }
}
