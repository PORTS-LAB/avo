// avo_init: applies the per-boot settings the Mac writes to the read-only
// avo_config disk (host side: BootConfig in host/AvoKit/Sources/AvoDaemonCore).
//
//   adb_keys           -> /data/misc/adb/adb_keys (the daemon's key; ADB stays
//                         authenticated even though only the daemon can reach it)
//   device_profile     -> identity properties via resetprop (spec §8)
//   device_profile_id,
//   rooted             -> avo.boot.* properties for the Bridge Agent's Hello
//   locale, time_zone  -> first boot only
//
// The disk holds UTF-8 JSON padded with zeros to a 4 KiB multiple.

#include <android-base/file.h>
#include <android-base/logging.h>
#include <android-base/properties.h>
#include <android-base/strings.h>
#include <json/reader.h>
#include <json/value.h>
#include <private/android_filesystem_config.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <set>
#include <string>
#include <vector>

namespace {

constexpr char kConfigDisk[] = "/dev/block/by-name/avo_config";
constexpr char kAdbKeys[] = "/data/misc/adb/adb_keys";
constexpr char kResetprop[] = "/system_ext/bin/resetprop";
constexpr char kFirstBootMarker[] = "/data/vendor/avo/first_boot_done";

bool ReadConfig(Json::Value* config) {
    std::string raw;
    if (!android::base::ReadFileToString(kConfigDisk, &raw)) {
        PLOG(ERROR) << "cannot read " << kConfigDisk;
        return false;
    }
    raw = raw.substr(0, raw.find('\0'));
    Json::Reader reader;
    if (!reader.parse(raw, *config) || !config->isObject() || (*config)["schema"].asInt() != 1) {
        LOG(ERROR) << "avo_config is not a schema 1 BootConfig";
        return false;
    }
    return true;
}

void AuthorizeAdbKeys(const Json::Value& keys) {
    std::string existing;
    android::base::ReadFileToString(kAdbKeys, &existing);
    std::set<std::string> lines;
    for (const auto& line : android::base::Split(existing, "\n")) {
        if (!line.empty()) lines.insert(line);
    }
    size_t before = lines.size();
    for (const auto& key : keys) {
        if (key.isString() && !key.asString().empty()) lines.insert(key.asString());
    }
    if (lines.size() == before) return;
    std::string content = android::base::Join(std::vector<std::string>(lines.begin(), lines.end()), "\n") + "\n";
    if (!android::base::WriteStringToFile(content, kAdbKeys, 0640, AID_SYSTEM, AID_SHELL)) {
        PLOG(ERROR) << "cannot write " << kAdbKeys;
    }
}

// Runs a program without a shell, so property values are never interpreted.
bool Run(const std::vector<std::string>& args) {
    pid_t pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        std::vector<char*> argv;
        for (const auto& arg : args) argv.push_back(const_cast<char*>(arg.c_str()));
        argv.push_back(nullptr);
        execv(argv[0], argv.data());
        _exit(127);
    }
    int status = 0;
    return waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// Identity properties are read-only once set, so they are rewritten in the
// property area with resetprop, as the spec describes. The stock image ships
// resetprop at kResetprop; without it the profile is reported but not applied.
void ApplyDeviceProfile(const Json::Value& properties) {
    if (properties.empty()) return;
    if (access(kResetprop, X_OK) != 0) {
        LOG(WARNING) << "resetprop missing; device profile not applied";
        return;
    }
    for (const auto& name : properties.getMemberNames()) {
        // The host validates names (identity properties only), but stay strict.
        if (!android::base::StartsWith(name, "ro.product.") && !android::base::StartsWith(name, "ro.build.") &&
            name != "ro.soc.manufacturer" && name != "ro.soc.model" && name != "ro.hardware") {
            LOG(WARNING) << "refusing to override " << name;
            continue;
        }
        if (!Run({kResetprop, name, properties[name].asString()})) LOG(WARNING) << "resetprop failed for " << name;
    }
}

}  // namespace

int main(int, char** argv) {
    android::base::InitLogging(argv, android::base::KernelLogger);
    Json::Value config;
    if (!ReadConfig(&config)) return 1;

    AuthorizeAdbKeys(config["adb_keys"]);
    ApplyDeviceProfile(config["device_profile"]);
    android::base::SetProperty("avo.boot.device_profile", config["device_profile_id"].asString());
    android::base::SetProperty("avo.boot.rooted", config["rooted"].asBool() ? "1" : "0");

    if (access(kFirstBootMarker, F_OK) != 0) {
        if (config["locale"].isString()) android::base::SetProperty("persist.sys.locale", config["locale"].asString());
        if (config["time_zone"].isString()) android::base::SetProperty("persist.sys.timezone", config["time_zone"].asString());
        android::base::WriteStringToFile("1", kFirstBootMarker);
    }
    if (config["default_density"].isInt()) {
        android::base::SetProperty("avo.boot.default_density", std::to_string(config["default_density"].asInt()));
    }
    LOG(INFO) << "applied avo_config (profile " << config["device_profile_id"].asString() << ")";
    return 0;
}
