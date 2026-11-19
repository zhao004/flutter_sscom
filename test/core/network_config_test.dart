import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('回环监听地址识别覆盖 localhost 和 IPv4/IPv6 本机地址', () {
    expect(isLoopbackBindAddress('127.0.0.1'), isTrue);
    expect(isLoopbackBindAddress('127.0.0.2'), isTrue);
    expect(isLoopbackBindAddress('::1'), isTrue);
    expect(isLoopbackBindAddress('[::1]'), isTrue);
    expect(isLoopbackBindAddress('localhost'), isTrue);
    expect(isLoopbackBindAddress('0.0.0.0'), isFalse);
    expect(isLoopbackBindAddress('192.168.1.20'), isFalse);
  });
}
