#include "register_types.h"

#include "ai/inference_engine.h"
#include "bridge/cot_message.h"
#include "hw/elrs_driver.h"
#include "hw/gps_driver.h"
#include "hw/serial_port.h"
#include "hw/usb_device_registry.h"
#include "hw/uvc_driver.h"
#include "hw/uvc_usbfs_driver.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include <dlfcn.h>

using namespace godot;

// Pins this shared library (and everything it dynamically links/loads,
// including the Vulkan loader and -- transitively -- the ICD driver
// Vulkan loads for us) so it is never actually unmapped, no matter how
// many times something later calls dlclose() on it.
//
// Why this exists: with Vulkan in play (InferenceEngine), this library
// crashed with SIGSEGV deep inside glibc's __run_exit_handlers on every
// single run on the Steam Frame's real hardware (Turnip/Freedreno
// driver) -- never reproduced on a desktop Intel GPU -- even in a
// minimal reproduction that does nothing but call
// InferenceEngine.is_vulkan_available() and quit. That call chain is
// just ncnn::create_gpu_instance(), which creates a VkInstance/VkDevice
// through the system Vulkan loader. The backtrace was always a garbage
// function pointer inside glibc's atexit-handler list, not a crash
// inside any identifiable code -- the signature of a dangling
// atexit()/__cxa_atexit registration: something registered a
// process-exit callback whose code lived in a shared object that was
// *unmapped* (via dlclose()) before libc's real exit() walked that list.
// Godot's GDExtension loader dlclose()'s every extension during its own
// shutdown sequence, before process exit -- unrelated to this project's
// "reloadable" setting, which only governs editor live-reload, not this
// final unload. If the Vulkan loader (or the driver it loads for us)
// registered such a callback expecting to survive until real process
// exit, and our own unmap is what breaks that chain, pinning ourselves
// here keeps everything we depend on resident regardless.
//
// dlopen()'ing our own already-loaded image with RTLD_NODELETE is the
// standard idiom for this: it adds no new mapping, just marks this one
// as "never munmap, no matter the refcount" -- correct to never match
// with a dlclose(), unlike every other dlopen in this codebase.
static void pin_self_against_unmap() {
	Dl_info info;
	if (dladdr((void *)&pin_self_against_unmap, &info) && info.dli_fname != nullptr) {
		dlopen(info.dli_fname, RTLD_NOW | RTLD_NODELETE);
	}
}

void initialize_fpvr_core_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	pin_self_against_unmap();

	ClassDB::register_class<fpvr::UsbDeviceRegistry>();
	ClassDB::register_class<fpvr::SerialPort>();
	ClassDB::register_class<fpvr::GpsDriver>();
	ClassDB::register_class<fpvr::ElrsDriver>();
	ClassDB::register_class<fpvr::CotMessage>();
	ClassDB::register_class<fpvr::UvcDriver>();
	ClassDB::register_class<fpvr::UvcUsbfsDriver>();
	ClassDB::register_class<fpvr::InferenceEngine>();
}

void uninitialize_fpvr_core_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	// InferenceEngine::shutdown() (called from its own destructor, see
	// inference_engine.cpp) now owns tearing down NCNN's Vulkan GPU
	// instance -- explicitly, deterministically, at the moment each
	// engine is actually dropped, rather than here. See that file's doc
	// comment for why that mattered (a real crash on the Steam Frame's
	// Vulkan driver, not reproducible elsewhere).
}

extern "C" {
GDExtensionBool GDE_EXPORT fpvr_core_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_fpvr_core_module);
	init_obj.register_terminator(uninitialize_fpvr_core_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
