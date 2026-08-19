#include <cstdint>

typedef uint64_t XrVersion;
typedef uint64_t XrFlags64;
typedef uint64_t XrSystemId;
typedef int64_t XrTime;
typedef int64_t XrDuration;
typedef uint32_t XrBool32;
typedef int32_t XrResult;
typedef int32_t XrStructureType;

typedef struct XrInstance_T* XrInstance;
typedef struct XrSession_T* XrSession;
typedef struct XrSpace_T* XrSpace;
typedef struct XrSwapchain_T* XrSwapchain;

typedef struct XrApplicationInfo {
    char applicationName[128];
    uint32_t applicationVersion;
    char engineName[128];
    uint32_t engineVersion;
    XrVersion apiVersion;
} XrApplicationInfo;

typedef struct XrInstanceCreateInfo {
    XrStructureType type;
    const void* next;
    XrFlags64 createFlags;
    XrApplicationInfo applicationInfo;
    uint32_t enabledApiLayerCount;
    const char* const* enabledApiLayerNames;
    uint32_t enabledExtensionCount;
    const char* const* enabledExtensionNames;
} XrInstanceCreateInfo;

typedef struct XrSystemGetInfo {
    XrStructureType type;
    const void* next;
    int32_t formFactor;
} XrSystemGetInfo;

typedef struct XrGraphicsRequirementsOpenGLKHR {
    XrStructureType type;
    void* next;
    XrVersion minApiVersionSupported;
    XrVersion maxApiVersionSupported;
} XrGraphicsRequirementsOpenGLKHR;

typedef struct XrGraphicsBindingOpenGLWin32KHR {
    XrStructureType type;
    const void* next;
    void* hDC;
    void* hGLRC;
} XrGraphicsBindingOpenGLWin32KHR;

typedef struct XrSessionCreateInfo {
    XrStructureType type;
    const void* next;
    XrFlags64 createFlags;
    XrSystemId systemId;
} XrSessionCreateInfo;

typedef struct XrVector3f {
    float x, y, z;
} XrVector3f;

typedef struct XrQuaternionf {
    float x, y, z, w;
} XrQuaternionf;

typedef struct XrPosef {
    XrQuaternionf orientation;
    XrVector3f position;
} XrPosef;

typedef struct XrReferenceSpaceCreateInfo {
    XrStructureType type;
    const void* next;
    int32_t referenceSpaceType;
    XrPosef poseInReferenceSpace;
} XrReferenceSpaceCreateInfo;

typedef struct XrViewConfigurationView {
    XrStructureType type;
    void* next;
    uint32_t recommendedImageRectWidth;
    uint32_t maxImageRectWidth;
    uint32_t recommendedImageRectHeight;
    uint32_t maxImageRectHeight;
    uint32_t recommendedSwapchainSampleCount;
    uint32_t maxSwapchainSampleCount;
} XrViewConfigurationView;

typedef struct XrSwapchainCreateInfo {
    XrStructureType type;
    const void* next;
    XrFlags64 createFlags;
    XrFlags64 usageFlags;
    int64_t format;
    uint32_t sampleCount;
    uint32_t width;
    uint32_t height;
    uint32_t faceCount;
    uint32_t arraySize;
    uint32_t mipCount;
} XrSwapchainCreateInfo;

typedef struct XrSwapchainImageOpenGLKHR {
    XrStructureType type;
    void* next;
    uint32_t image;
} XrSwapchainImageOpenGLKHR;

typedef struct XrEventDataBuffer {
    XrStructureType type;
    const void* next;
    uint8_t varying[4000];
} XrEventDataBuffer;

typedef struct XrEventDataSessionStateChanged {
    XrStructureType type;
    const void* next;
    XrSession session;
    int32_t state;
    XrTime time;
} XrEventDataSessionStateChanged;

typedef struct XrFrameWaitInfo {
    XrStructureType type;
    const void* next;
} XrFrameWaitInfo;

typedef struct XrFrameState {
    XrStructureType type;
    void* next;
    XrTime predictedDisplayTime;
    XrDuration predictedDisplayPeriod;
    XrBool32 shouldRender;
} XrFrameState;

typedef struct XrFrameBeginInfo {
    XrStructureType type;
    const void* next;
} XrFrameBeginInfo;

typedef struct XrViewLocateInfo {
    XrStructureType type;
    const void* next;
    int32_t viewConfigurationType;
    XrTime displayTime;
    XrSpace space;
} XrViewLocateInfo;

typedef struct XrViewState {
    XrStructureType type;
    void* next;
    XrFlags64 viewStateFlags;
} XrViewState;

typedef struct XrFovf {
    float angleLeft, angleRight, angleUp, angleDown;
} XrFovf;

typedef struct XrView {
    XrStructureType type;
    void* next;
    XrPosef pose;
    XrFovf fov;
} XrView;

typedef struct XrSwapchainImageAcquireInfo {
    XrStructureType type;
    const void* next;
} XrSwapchainImageAcquireInfo;

typedef struct XrSwapchainImageWaitInfo {
    XrStructureType type;
    const void* next;
    XrDuration timeout;
} XrSwapchainImageWaitInfo;

typedef struct XrSwapchainImageReleaseInfo {
    XrStructureType type;
    const void* next;
} XrSwapchainImageReleaseInfo;

typedef struct XrOffset2Di {
    int32_t x, y;
} XrOffset2Di;

typedef struct XrExtent2Di {
    int32_t width, height;
} XrExtent2Di;

typedef struct XrRect2Di {
    XrOffset2Di offset;
    XrExtent2Di extent;
} XrRect2Di;

typedef struct XrSwapchainSubImage {
    XrSwapchain swapchain;
    XrRect2Di imageRect;
    uint32_t imageArrayIndex;
} XrSwapchainSubImage;

typedef struct XrCompositionLayerProjectionView {
    XrStructureType type;
    const void* next;
    XrPosef pose;
    XrFovf fov;
    XrSwapchainSubImage subImage;
} XrCompositionLayerProjectionView;

typedef struct XrCompositionLayerProjection {
    XrStructureType type;
    const void* next;
    XrFlags64 layerFlags;
    XrSpace space;
    uint32_t viewCount;
    const XrCompositionLayerProjectionView* views;
} XrCompositionLayerProjection;

typedef struct XrExtent2Df {
    float width, height;
} XrExtent2Df;

typedef struct XrCompositionLayerQuad {
    XrStructureType type;
    const void* next;
    XrFlags64 layerFlags;
    XrSpace space;
    int32_t eyeVisibility;
    XrSwapchainSubImage subImage;
    XrPosef pose;
    XrExtent2Df size;
} XrCompositionLayerQuad;

typedef struct XrSessionBeginInfo {
    XrStructureType type;
    const void* next;
    int32_t primaryViewConfigurationType;
} XrSessionBeginInfo;

typedef struct XrFrameEndInfo {
    XrStructureType type;
    const void* next;
    XrTime displayTime;
    int32_t environmentBlendMode;
    uint32_t layerCount;
    const void* const* layers;
} XrFrameEndInfo;

XrResult xrCreateInstance(const XrInstanceCreateInfo*, XrInstance*);
XrResult xrDestroyInstance(XrInstance);
XrResult xrGetSystem(XrInstance, const XrSystemGetInfo*, XrSystemId*);
XrResult xrGetInstanceProcAddr(XrInstance, const char*, void**);
XrResult xrCreateSession(XrInstance, const XrSessionCreateInfo*, XrSession*);
XrResult xrDestroySession(XrSession);
XrResult xrCreateReferenceSpace(XrSession, const XrReferenceSpaceCreateInfo*, XrSpace*);
XrResult xrEnumerateViewConfigurationViews(XrInstance, XrSystemId, int32_t,
                                           uint32_t, uint32_t*, XrViewConfigurationView*);
XrResult xrEnumerateSwapchainFormats(XrSession, uint32_t, uint32_t*, int64_t*);
XrResult xrCreateSwapchain(XrSession, const XrSwapchainCreateInfo*, XrSwapchain*);
XrResult xrEnumerateSwapchainImages(XrSwapchain, uint32_t, uint32_t*, void*);
XrResult xrAcquireSwapchainImage(XrSwapchain, const XrSwapchainImageAcquireInfo*, uint32_t*);
XrResult xrWaitSwapchainImage(XrSwapchain, const XrSwapchainImageWaitInfo*);
XrResult xrReleaseSwapchainImage(XrSwapchain, const XrSwapchainImageReleaseInfo*);
XrResult xrBeginSession(XrSession, const XrSessionBeginInfo*);
XrResult xrEndSession(XrSession);
XrResult xrPollEvent(XrInstance, XrEventDataBuffer*);
XrResult xrWaitFrame(XrSession, const XrFrameWaitInfo*, XrFrameState*);
XrResult xrBeginFrame(XrSession, const XrFrameBeginInfo*);
XrResult xrLocateViews(XrSession, const XrViewLocateInfo*, XrViewState*,
                       uint32_t, uint32_t*, XrView*);
XrResult xrEndFrame(XrSession, const XrFrameEndInfo*);

typedef XrResult (__stdcall *PFN_xrGetOpenGLGraphicsRequirementsKHR)(
    XrInstance, XrSystemId, XrGraphicsRequirementsOpenGLKHR*);

typedef struct XrActionSet_T* XrActionSet;
typedef struct XrAction_T* XrAction;
typedef uint64_t XrPath;

typedef struct XrActionSetCreateInfo {
    XrStructureType type;
    const void* next;
    char actionSetName[64];
    char localizedActionSetName[128];
    uint32_t priority;
} XrActionSetCreateInfo;

typedef struct XrActionCreateInfo {
    XrStructureType type;
    const void* next;
    char actionName[64];
    int32_t actionType;
    uint32_t countSubactionPaths;
    const XrPath* subactionPaths;
    char localizedActionName[128];
} XrActionCreateInfo;

typedef struct XrActionSuggestedBinding {
    XrAction action;
    XrPath binding;
} XrActionSuggestedBinding;

typedef struct XrInteractionProfileSuggestedBinding {
    XrStructureType type;
    const void* next;
    XrPath interactionProfile;
    uint32_t countSuggestedBindings;
    const XrActionSuggestedBinding* suggestedBindings;
} XrInteractionProfileSuggestedBinding;

typedef struct XrSessionActionSetsAttachInfo {
    XrStructureType type;
    const void* next;
    uint32_t countActionSets;
    const XrActionSet* actionSets;
} XrSessionActionSetsAttachInfo;

typedef struct XrActiveActionSet {
    XrActionSet actionSet;
    XrPath subactionPath;
} XrActiveActionSet;

typedef struct XrActionsSyncInfo {
    XrStructureType type;
    const void* next;
    uint32_t countActiveActionSets;
    const XrActiveActionSet* activeActionSets;
} XrActionsSyncInfo;

typedef struct XrActionStateGetInfo {
    XrStructureType type;
    const void* next;
    XrAction action;
    XrPath subactionPath;
} XrActionStateGetInfo;

typedef struct XrActionStateBoolean {
    XrStructureType type;
    void* next;
    XrBool32 currentState;
    XrBool32 changedSinceLastSync;
    XrTime lastChangeTime;
    XrBool32 isActive;
} XrActionStateBoolean;

typedef struct XrActionStateFloat {
    XrStructureType type;
    void* next;
    float currentState;
    XrBool32 changedSinceLastSync;
    XrTime lastChangeTime;
    XrBool32 isActive;
} XrActionStateFloat;

typedef struct XrVector2f {
    float x, y;
} XrVector2f;

typedef struct XrActionStateVector2f {
    XrStructureType type;
    void* next;
    XrVector2f currentState;
    XrBool32 changedSinceLastSync;
    XrTime lastChangeTime;
    XrBool32 isActive;
} XrActionStateVector2f;

typedef struct XrActionSpaceCreateInfo {
    XrStructureType type;
    const void* next;
    XrAction action;
    XrPath subactionPath;
    XrPosef poseInActionSpace;
} XrActionSpaceCreateInfo;

typedef struct XrSpaceLocation {
    XrStructureType type;
    void* next;
    XrFlags64 locationFlags;
    XrPosef pose;
} XrSpaceLocation;

XrResult xrStringToPath(XrInstance, const char*, XrPath*);
XrResult xrCreateActionSet(XrInstance, const XrActionSetCreateInfo*, XrActionSet*);
XrResult xrCreateAction(XrActionSet, const XrActionCreateInfo*, XrAction*);
XrResult xrSuggestInteractionProfileBindings(XrInstance,
                                             const XrInteractionProfileSuggestedBinding*);
XrResult xrAttachSessionActionSets(XrSession, const XrSessionActionSetsAttachInfo*);
XrResult xrSyncActions(XrSession, const XrActionsSyncInfo*);
XrResult xrGetActionStateBoolean(XrSession, const XrActionStateGetInfo*,
                                 XrActionStateBoolean*);
XrResult xrGetActionStateFloat(XrSession, const XrActionStateGetInfo*,
                               XrActionStateFloat*);
XrResult xrGetActionStateVector2f(XrSession, const XrActionStateGetInfo*,
                                  XrActionStateVector2f*);
XrResult xrCreateActionSpace(XrSession, const XrActionSpaceCreateInfo*, XrSpace*);
XrResult xrLocateSpace(XrSpace, XrSpace, XrTime, XrSpaceLocation*);