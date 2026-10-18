import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct GuestAudioPolicyTests {
    /// /vendor/etc/primary_audio_policy_configuration.xml of AOSP Cuttlefish
    /// 16373615 (aosp_cf_arm64_only_phone-userdebug, Android 17), license cut.
    static let cuttlefish = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- Default Primary Audio HAL Module Audio Policy Configuration include file -->
        <module name="primary" halVersion="3.0">
            <attachedDevices>
                <item>Speaker</item>
                <item>Built-In Mic</item>
                <item>Telephony Tx</item>
                <item>Telephony Rx</item>
                <item>FM Tuner</item>
            </attachedDevices>
            <defaultOutputDevice>Speaker</defaultOutputDevice>
            <mixPorts>
                <mixPort name="primary output" role="source" flags="AUDIO_OUTPUT_FLAG_PRIMARY">
                    <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
                             samplingRates="8000 11025 16000 32000 44100 48000"
                             channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO"/>
                </mixPort>
                <mixPort name="compressed_offload" role="source" maxOpenCount="1" maxActiveCount="1"
                         flags="AUDIO_OUTPUT_FLAG_DIRECT AUDIO_OUTPUT_FLAG_COMPRESS_OFFLOAD AUDIO_OUTPUT_FLAG_NON_BLOCKING">
                    <profile name="" format="AUDIO_FORMAT_APE"
                             samplingRates="44100 48000"
                             channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO"/>
                    <profile name="" format="AUDIO_FORMAT_MP3"
                             samplingRates="44100 48000"
                             channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO"/>
                    <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
                             samplingRates="44100 48000"
                             channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO"/>
                </mixPort>
                <mixPort name="mmap_no_irq_out" role="source" flags="AUDIO_OUTPUT_FLAG_DIRECT AUDIO_OUTPUT_FLAG_MMAP_NOIRQ">
                     <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
                              samplingRates="44100 48000"
                              channelMasks="AUDIO_CHANNEL_OUT_STEREO"/>
                </mixPort>
                <mixPort name="primary input" role="sink">
                    <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
                             samplingRates="8000 11025 16000 32000 44100 48000"
                             channelMasks="AUDIO_CHANNEL_IN_MONO AUDIO_CHANNEL_IN_STEREO"/>
                </mixPort>
                <mixPort name="mmap_no_irq_in" role="sink" flags="AUDIO_INPUT_FLAG_MMAP_NOIRQ">
                    <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
                                     samplingRates="44100 48000"
                                     channelMasks="AUDIO_CHANNEL_IN_MONO AUDIO_CHANNEL_IN_STEREO"/>
                </mixPort>
                <mixPort name="telephony_tx" role="source">
                    <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
                             samplingRates="8000 11025 16000 32000 44100 48000"
                             channelMasks="AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO"/>
                </mixPort>
                <mixPort name="telephony_rx" role="sink">
                    <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
                             samplingRates="8000 11025 16000 32000 44100 48000"
                             channelMasks="AUDIO_CHANNEL_IN_MONO AUDIO_CHANNEL_IN_STEREO"/>
                </mixPort>

                <mixPort name="fm_tuner" role="sink">
                    <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
                             samplingRates="8000 11025 16000 32000 44100 48000"
                             channelMasks="AUDIO_CHANNEL_IN_MONO AUDIO_CHANNEL_IN_STEREO"/>
                </mixPort>
           </mixPorts>
           <devicePorts>
                <devicePort tagName="Speaker" type="AUDIO_DEVICE_OUT_SPEAKER" role="sink">
                </devicePort>
                <devicePort tagName="Telephony Tx" type="AUDIO_DEVICE_OUT_TELEPHONY_TX" role="sink">
                    <gains>
                        <gain defaultValueMB="0" maxValueMB="4000" minValueMB="-8800" mode="AUDIO_GAIN_MODE_JOINT" name="" stepValueMB="100" useForVolume="false" />
                    </gains>
                </devicePort>

                <devicePort tagName="Built-In Mic" type="AUDIO_DEVICE_IN_BUILTIN_MIC" address="bottom" role="source">
                </devicePort>
                <devicePort tagName="Telephony Rx" type="AUDIO_DEVICE_IN_TELEPHONY_RX" role="source">
                </devicePort>

                <devicePort tagName="FM Tuner" type="AUDIO_DEVICE_IN_FM_TUNER" role="source">
                </devicePort>
            </devicePorts>
            <routes>
                <route type="mix" sink="Speaker"
                       sources="primary output,compressed_offload,mmap_no_irq_out"/>
                <route type="mix" sink="primary input"
                       sources="Built-In Mic"/>
                <route type="mix" sink="mmap_no_irq_in"
                       sources="Built-In Mic"/>

                <route type="mix" sink="telephony_rx"
                       sources="Telephony Rx"/>
                <route type="mix" sink="Telephony Tx"
                       sources="telephony_tx"/>

                <route type="mix" sink="fm_tuner"
                       sources="FM Tuner"/>
            </routes>
        </module>
        """

    static func document(_ text: String) throws -> XMLDocument {
        try XMLDocument(xmlString: text, options: [])
    }

    static func values(_ xpath: String, in document: XMLDocument) throws -> [String] {
        try document.nodes(forXPath: xpath).compactMap(\.stringValue)
    }

    @Test func takesTheStubPortsOutOfCuttlefishsPrimaryModule() throws {
        let edited = try #require(GuestAudioPolicy.withoutStubPorts(Self.cuttlefish))
        let document = try Self.document(edited)
        #expect(try Self.values("/module/mixPorts/mixPort/@name", in: document)
                == ["primary output", "primary input", "telephony_tx", "telephony_rx", "fm_tuner"])
        #expect(try Self.values("/module/routes/route/@sink", in: document)
                == ["Speaker", "primary input", "telephony_rx", "Telephony Tx", "fm_tuner"])
        #expect(try Self.values("/module/routes/route[@sink='Speaker']/@sources", in: document) == ["primary output"])
        for flag in GuestAudioPolicy.stubFlags {
            #expect(!edited.contains(flag))
        }
        // The rest stays: devices, profiles, gains, comments.
        #expect(try Self.values("/module/attachedDevices/item", in: document).count == 5)
        #expect(try Self.values("/module/devicePorts/devicePort/@tagName", in: document).count == 5)
        #expect(try Self.values("/module/mixPorts/mixPort[@name='primary output']/profile/@samplingRates", in: document)
                == ["8000 11025 16000 32000 44100 48000"])
        #expect(try Self.values("//gain/@maxValueMB", in: document) == ["4000"])
        #expect(edited.contains("<!-- Default Primary Audio HAL Module Audio Policy Configuration include file -->"))
        #expect(edited.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\""))
    }

    /// The Speaker gets the primary output's profiles (Cuttlefish declares it
    /// without any), so apps see mono and stereo, not "anything".
    @Test func givesTheSpeakerTheProfilesOfItsMixPort() throws {
        let edited = try #require(GuestAudioPolicy.adjusted(Self.cuttlefish))
        let document = try Self.document(edited)
        #expect(try Self.values("/module/devicePorts/devicePort[@tagName='Speaker']/profile/@channelMasks", in: document)
                == ["AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO"])
        #expect(try Self.values("/module/devicePorts/devicePort[@tagName='Speaker']/profile/@samplingRates", in: document)
                == ["8000 11025 16000 32000 44100 48000"])
        // The voice-call output gets its mix port's profiles too (voice-chat
        // SDKs look at it), ahead of its gains; inputs stay as they were.
        #expect(try Self.values("/module/devicePorts/devicePort[@tagName='Telephony Tx']/profile/@channelMasks", in: document)
                == ["AUDIO_CHANNEL_OUT_MONO AUDIO_CHANNEL_OUT_STEREO"])
        #expect(try Self.values("/module/devicePorts/devicePort[@tagName='Telephony Tx']/gains/gain/@maxValueMB", in: document) == ["4000"])
        #expect(try Self.values("/module/devicePorts/devicePort[@tagName='Built-In Mic']/profile", in: document).isEmpty)
        // The stub ports go as before.
        #expect(!GuestAudioPolicy.stubFlags.contains { edited.contains($0) })
        #expect(GuestAudioPolicy.adjusted(edited) == nil)
        // A file with only the speaker to fix is edited too.
        let stubsGone = try #require(GuestAudioPolicy.withoutStubPorts(Self.cuttlefish))
        #expect(GuestAudioPolicy.adjusted(stubsGone) != nil)
    }

    /// A speaker no mix port reaches still gets 48 kHz stereo.
    @Test func aSpeakerWithoutRoutesGetsStereo() throws {
        let text = """
            <module name="primary"><devicePorts><devicePort tagName="Speaker" type="AUDIO_DEVICE_OUT_SPEAKER" role="sink"/></devicePorts></module>
            """
        let document = try Self.document(try #require(GuestAudioPolicy.withSpeakerProfiles(text)))
        #expect(try Self.values("//devicePort/profile/@channelMasks", in: document) == ["AUDIO_CHANNEL_OUT_STEREO"])
        #expect(try Self.values("//devicePort/profile/@samplingRates", in: document) == ["48000"])
    }

    @Test func anEditedFileIsLeftAlone() throws {
        let edited = try #require(GuestAudioPolicy.withoutStubPorts(Self.cuttlefish))
        #expect(GuestAudioPolicy.withoutStubPorts(edited) == nil)
    }

    @Test func onlyThePrimaryModuleChanges() throws {
        let configuration = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <audioPolicyConfiguration version="7.0" xmlns:xi="http://www.w3.org/2001/XInclude">
                <globalConfiguration speaker_drc_enabled="false"/>
                <modules>
                    <module name="primary" halVersion="3.0">
                        <mixPorts>
                            <mixPort name="primary output" role="source" flags="AUDIO_OUTPUT_FLAG_PRIMARY|AUDIO_OUTPUT_FLAG_FAST"/>
                            <mixPort name="mmap out" role="source" flags="AUDIO_OUTPUT_FLAG_DIRECT|AUDIO_OUTPUT_FLAG_MMAP_NOIRQ"/>
                        </mixPorts>
                        <routes>
                            <route type="mix" sink="Speaker" sources="mmap out, primary output"/>
                            <route type="mix" sink="Earpiece" sources="mmap out"/>
                        </routes>
                    </module>
                    <module name="usb" halVersion="2.0">
                        <mixPorts>
                            <mixPort name="usb mmap" role="source" flags="AUDIO_OUTPUT_FLAG_MMAP_NOIRQ"/>
                        </mixPorts>
                    </module>
                    <xi:include href="r_submix_audio_policy_configuration.xml"/>
                </modules>
            </audioPolicyConfiguration>
            """
        let edited = try #require(GuestAudioPolicy.withoutStubPorts(configuration))
        let document = try Self.document(edited)
        #expect(try Self.values("//module[@name='primary']/mixPorts/mixPort/@name", in: document) == ["primary output"])
        // "|"-separated flags count too; a route with no source left goes.
        #expect(try Self.values("//module[@name='primary']/routes/route/@sink", in: document) == ["Speaker"])
        #expect(try Self.values("//module[@name='primary']/routes/route/@sources", in: document) == ["primary output"])
        // Other HAL modules are not the primary module's stubs.
        #expect(try Self.values("//module[@name='usb']/mixPorts/mixPort/@name", in: document) == ["usb mmap"])
        #expect(edited.contains("<xi:include href=\"r_submix_audio_policy_configuration.xml\"/>"))
    }

    @Test func aConfigurationWithoutStubsOrNotXMLStaysAsItIs() {
        let plain = """
            <module name="primary" halVersion="3.0">
                <mixPorts>
                    <mixPort name="primary output" role="source" flags="AUDIO_OUTPUT_FLAG_PRIMARY"/>
                </mixPorts>
            </module>
            """
        #expect(GuestAudioPolicy.withoutStubPorts(plain) == nil)
        #expect(GuestAudioPolicy.withoutStubPorts("") == nil)
        #expect(GuestAudioPolicy.withoutStubPorts("<module name=\"primary\"><mixPorts>") == nil)
    }

    @Test func stagesOneFilePerPath() {
        #expect(GuestAudioPolicy.stagedPath(for: "/vendor/etc/primary_audio_policy_configuration.xml")
                == "/data/local/tmp/avo-audio/vendor_etc_primary_audio_policy_configuration.xml")
        #expect(GuestAudioPolicy.stagedPath(for: "/odm/etc/primary_audio_policy_configuration.xml")
                != GuestAudioPolicy.stagedPath(for: "/vendor/etc/primary_audio_policy_configuration.xml"))
    }

    @Test func readsTheLoadedPolicyFromDumpsys() {
        // `dumpsys media.audio_policy` (Android 17, trimmed).
        let before = """
             Hardware modules (3):
              1. Handle: 10; "primary"
               - Output MixPorts (4):
                  1. "primary output"; 0x0002 (AUDIO_OUTPUT_FLAG_PRIMARY)
                  2. "compressed_offload"; 0x0031 (AUDIO_OUTPUT_FLAG_DIRECT|AUDIO_OUTPUT_FLAG_COMPRESS_OFFLOAD|AUDIO_OUTPUT_FLAG_NON_BLOCKING)
                  3. "mmap_no_irq_out"; 0x4001 (AUDIO_OUTPUT_FLAG_DIRECT|AUDIO_OUTPUT_FLAG_MMAP_NOIRQ)
            """
        let after = """
             Hardware modules (3):
              1. Handle: 10; "primary"
               - Output MixPorts (2):
                  1. "primary output"; 0x0002 (AUDIO_OUTPUT_FLAG_PRIMARY)
                  2. "telephony_tx"; 0x0000 (AUDIO_OUTPUT_FLAG_NONE)
            """
        #expect(GuestAudioPolicy.hasModules(dump: before) && GuestAudioPolicy.offersStubPorts(dump: before))
        #expect(GuestAudioPolicy.hasModules(dump: after) && !GuestAudioPolicy.offersStubPorts(dump: after))
        #expect(!GuestAudioPolicy.hasModules(dump: "Can't find service: media.audio_policy"))
    }

    @Test func findsTheFilesWhereTheHALLooks() {
        #expect(GuestAudioPolicy.findCommand.contains("/vendor/etc/*.xml"))
        #expect(GuestAudioPolicy.findCommand.contains("/odm/etc/*.xml"))
        #expect(GuestAudioPolicy.findCommand.hasPrefix("grep -l -s -E "))
    }
}
