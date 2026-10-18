import Foundation

/// The audio policy configuration Cuttlefish's audio HAL should have
/// (HostAgent, "Audio").
///
/// The HAL (hardware/interfaces/audio/aidl/default, `ModulePrimary`) plays and
/// records through ALSA card 0, the engine's virtio-snd
/// (engine/hvf/vmm/src/virtio/sound.rs), on its ordinary streams only. Its
/// MMAP streams are stubs ("there is no support for MMAP audio I/O on CVD"):
/// a simulated DSP clock takes the output and drops it, and input is random
/// bytes. Its compressed-offload stream reads the clip's header and only
/// pretends to play. The image's primary module still declares a mix port
/// for each, and the HAL reports MMAP as supported because of them, so
/// AAudio sends every low-latency stream (games: Unreal, Wwise, Oboe) to
/// MMAP and Android's media player offloads long MP3s: both stay silent while
/// YouTube's AudioTrack, through the mixer, plays. Without those ports the
/// HAL reports MMAP as never supported (audioserver then does not even start
/// AAudio's MMAP service), AAudio uses AudioTrack and AudioRecord like
/// OpenSL ES and Java apps do, nothing is offloaded, and all audio goes
/// through the mixer.
enum GuestAudioPolicy {
    /// Mix port flags whose streams the primary module only simulates
    /// (StreamOutMmapStub, StreamInMmapStub, StreamOutOffloadStub).
    static let stubFlags: Set<String> = [
        "AUDIO_OUTPUT_FLAG_MMAP_NOIRQ", "AUDIO_INPUT_FLAG_MMAP_NOIRQ", "AUDIO_OUTPUT_FLAG_COMPRESS_OFFLOAD",
    ]

    /// Output devices that need profiles of their own: the speaker apps see
    /// (AudioDeviceInfo), and the voice-call output that voice-chat SDKs
    /// look at (Delta Force's GVoice asked for an 8-channel player, as on a
    /// speaker without profiles, and failed every 3 s).
    static let appOutputDevices: Set<String> = ["AUDIO_DEVICE_OUT_SPEAKER", "AUDIO_DEVICE_OUT_TELEPHONY_TX"]

    /// Lists the configuration files that declare such ports or devices:
    /// where the HAL looks for audio_policy_configuration.xml (and the files
    /// it includes).
    static let findCommand = "grep -l -s -E 'AUDIO_(OUTPUT|INPUT)_FLAG_MMAP_NOIRQ|AUDIO_OUTPUT_FLAG_COMPRESS_OFFLOAD|AUDIO_DEVICE_OUT_SPEAKER' "
        + "/odm/etc/*.xml /odm/etc/audio/*/*.xml /vendor/etc/*.xml /vendor/etc/audio/*/*.xml"

    /// Both edits below; nil when neither changes `text`.
    static func adjusted(_ text: String) -> String? {
        let withoutStubs = withoutStubPorts(text)
        return withSpeakerProfiles(withoutStubs ?? text) ?? withoutStubs
    }

    /// Where the edited files wait; each is bind-mounted over the image's file.
    static let staging = "/data/local/tmp/avo-audio"

    /// The staged copy of `path`: `/vendor/etc/a.xml` → `…/vendor_etc_a.xml`.
    static func stagedPath(for path: String) -> String {
        staging + "/" + path.split(separator: "/").joined(separator: "_")
    }

    /// `text` without the stub mix ports of its primary module, and its routes
    /// without them (a route left with no source, or whose sink was one of
    /// them, goes too). Nil when there is nothing to take out, or `text` is
    /// not XML: the file stays as it is.
    static func withoutStubPorts(_ text: String) -> String? {
        guard let document = try? XMLDocument(xmlString: text, options: [.nodePreserveAll]) else { return nil }
        var removed = false
        for module in primaryModules(document) {
            var stubs: Set<String> = []
            for port in ((try? module.nodes(forXPath: "mixPorts/mixPort")) ?? []).compactMap({ $0 as? XMLElement }) {
                let flags = (port.attribute(forName: "flags")?.stringValue ?? "")
                    .split(whereSeparator: { $0.isWhitespace || $0 == "|" }).map(String.init)
                guard flags.contains(where: stubFlags.contains), let name = port.attribute(forName: "name")?.stringValue else { continue }
                stubs.insert(name)
                port.detach()
            }
            guard !stubs.isEmpty else { continue }
            removed = true
            for route in ((try? module.nodes(forXPath: "routes/route")) ?? []).compactMap({ $0 as? XMLElement }) {
                let sources = (route.attribute(forName: "sources")?.stringValue ?? "")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let kept = sources.filter { !stubs.contains($0) }
                if (kept.isEmpty && !sources.isEmpty) || stubs.contains(route.attribute(forName: "sink")?.stringValue ?? "") {
                    route.detach()
                } else if kept.count < sources.count {
                    route.attribute(forName: "sources")?.stringValue = kept.joined(separator: ",")
                }
            }
        }
        return removed ? document.xmlString(options: [.nodePreserveAll]) : nil
    }

    /// `text` with profiles on each speaker device port that has none: those
    /// of the mix ports routed to it (PCM only). Cuttlefish's Speaker port has
    /// none ("dynamic"), so AudioDeviceInfo lists no channel counts, and a
    /// sound engine that takes that for "anything" can ask for 7.1: Call of
    /// Duty: Mobile's OpenSL ES player was refused that way ("requested 8
    /// channels but mask … has 6 channel bits set") and the game stayed
    /// silent while YouTube played. Nil when no port changes.
    static func withSpeakerProfiles(_ text: String) -> String? {
        guard let document = try? XMLDocument(xmlString: text, options: [.nodePreserveAll]) else { return nil }
        let elements = { (node: XMLNode, xpath: String) in
            ((try? node.nodes(forXPath: xpath)) ?? []).compactMap { $0 as? XMLElement }
        }
        var changed = false
        for module in primaryModules(document) {
            for port in elements(module, "devicePorts/devicePort") {
                guard port.attribute(forName: "role")?.stringValue == "sink",
                      appOutputDevices.contains(port.attribute(forName: "type")?.stringValue ?? ""),
                      port.elements(forName: "profile").isEmpty,
                      let tag = port.attribute(forName: "tagName")?.stringValue else { continue }
                let sources = elements(module, "routes/route").filter { $0.attribute(forName: "sink")?.stringValue == tag }
                    .flatMap { ($0.attribute(forName: "sources")?.stringValue ?? "").split(separator: ",") }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                var seen: Set<String> = []
                var profiles = elements(module, "mixPorts/mixPort")
                    .filter { sources.contains($0.attribute(forName: "name")?.stringValue ?? "") }
                    .flatMap { $0.elements(forName: "profile") }
                    .filter { ($0.attribute(forName: "format")?.stringValue ?? "").hasPrefix("AUDIO_FORMAT_PCM") }
                    .filter { seen.insert($0.xmlString).inserted }
                    .compactMap { $0.copy() as? XMLElement }
                if profiles.isEmpty, let stereo = try? XMLElement(xmlString: #"<profile name="" format="AUDIO_FORMAT_PCM_16_BIT" samplingRates="48000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/>"#) {
                    profiles = [stereo]
                }
                for (index, profile) in profiles.enumerated() { port.insertChild(profile, at: index) }
                changed = changed || !profiles.isEmpty
            }
        }
        return changed ? document.xmlString(options: [.nodePreserveAll]) : nil
    }

    /// A file of its own (`<module>` is the root, as xi:include'd) or one
    /// module of many. "primary" is the HAL's ModulePrimary ("default").
    private static func primaryModules(_ document: XMLDocument) -> [XMLElement] {
        ((try? document.nodes(forXPath: "//module")) ?? []).compactMap { $0 as? XMLElement }
            .filter { ["primary", "default"].contains($0.attribute(forName: "name")?.stringValue) }
    }

    /// `dumpsys media.audio_policy` from an audioserver that has its HAL's
    /// modules (not one still starting, or none at all).
    static func hasModules(dump: String) -> Bool {
        dump.contains("Hardware modules")
    }

    /// Whether that audioserver still offers one of the stub ports.
    static func offersStubPorts(dump: String) -> Bool {
        stubFlags.contains { dump.contains($0) }
    }
}
