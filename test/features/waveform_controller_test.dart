import 'dart:typed_data';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/waveform/application/waveform_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';

void main() {
  test('波形独立接收、暂停和清空不影响终端数据流', () async {
    final transport = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final terminal = TerminalController(
      transport: transport,
      textEncoder: const Utf8TextByteEncoder(),
      backendLabel: '测试串口',
      initialConfig: const SerialConfig(portName: 'COM1', baudRate: 115200),
    );
    final waveform = WaveformController(
      terminal: terminal,
      capacitySamples: 64,
      maxBuckets: 8,
      flushInterval: const Duration(milliseconds: 10),
      maxPendingBytes: 16,
    );

    try {
      await terminal.initialize();
      await terminal.open();
      transport.injectData(Uint8List.fromList(<int>[1, 2, 3, 4]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(waveform.state.value.totalSamples, 4);
      expect(waveform.state.value.windowSamples, 4);
      expect(waveform.state.value.latestSample, 4);
      expect(terminal.state.value.receivedBytes, 4);

      waveform.setPaused(true);
      transport.injectData(Uint8List.fromList(<int>[5, 6]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(waveform.state.value.totalSamples, 4);
      expect(terminal.state.value.receivedBytes, 6);

      waveform.setPaused(false);
      transport.injectData(Uint8List.fromList(<int>[7]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(waveform.state.value.totalSamples, 5);
      expect(waveform.state.value.latestSample, 7);

      waveform.clear();
      expect(waveform.state.value.totalSamples, 0);
      expect(waveform.state.value.buckets, isEmpty);
      expect(terminal.state.value.receivedBytes, 7);
    } finally {
      await waveform.dispose();
      await terminal.dispose();
    }
  });

  test('高频接收时波形窗口保持有界且终端累计不丢失', () async {
    final transport = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final terminal = TerminalController(
      transport: transport,
      textEncoder: const Utf8TextByteEncoder(),
      backendLabel: '测试串口',
      initialConfig: const SerialConfig(portName: 'COM1', baudRate: 115200),
    );
    final waveform = WaveformController(
      terminal: terminal,
      capacitySamples: 4096,
      maxBuckets: 16,
      flushInterval: const Duration(milliseconds: 5),
      maxPendingBytes: 4096,
    );

    try {
      await terminal.initialize();
      await terminal.open();
      final payload = Uint8List.fromList(
        List<int>.generate(64 * 1024, (index) => index & 0xFF),
      );
      transport.injectData(payload);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(terminal.state.value.receivedBytes, payload.length);
      expect(waveform.state.value.totalSamples, payload.length);
      expect(waveform.state.value.windowSamples, 4096);
      expect(waveform.state.value.discardedSamples, payload.length - 4096);
      expect(waveform.state.value.buckets.length, lessThanOrEqualTo(16));
    } finally {
      await waveform.dispose();
      await terminal.dispose();
    }
  });
}
