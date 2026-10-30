#!/usr/bin/env python3
"""Run the real XiaomiWearAdapter with a virtual Android clock and SDK fakes.

Requires JDK 17+ and the Kotlin compiler already cached by Gradle. No downloads.
The Android/AAR compilation remains a separate production compatibility check.
"""
from pathlib import Path
import os
import subprocess
import tempfile

here = Path(__file__).resolve().parent
main = here.parents[1] / 'main/kotlin/top/jxcz/orialis'
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
version = '2.2.21'
artifacts = ['kotlin-compiler-embeddable', 'kotlin-stdlib', 'kotlin-script-runtime', 'kotlin-reflect']
compiler = []
for artifact in artifacts:
    jars = list((cache / 'org.jetbrains.kotlin' / artifact / version).glob('*/*.jar'))
    if not jars:
        raise SystemExit(f'Missing cached {artifact} {version}; run the project Android build first')
    compiler.append(str(jars[0]))
for group, artifact in [('org.jetbrains.intellij.deps', 'trove4j'), ('org.jetbrains', 'annotations'), ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm')]:
    jars = list((cache / group / artifact).glob('*/*/*.jar'))
    if jars:
        compiler.append(str(jars[-1]))
java = Path(os.environ.get('JAVA_HOME', '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home')) / 'bin/java'
if not java.exists():
    java = Path('java')

stubs = {
'Context.kt': '''package android.content
open class Context { val applicationContext: Context get() = this }
''',
'Clock.kt': '''package android.os
class Looper { companion object { private val main = Looper(); fun getMainLooper() = main; fun myLooper() = main } }
object Clock {
    var now = 0L
    private var sequence = 0L
    private data class Entry(val at: Long, val seq: Long, val run: Runnable)
    private val queue = mutableListOf<Entry>()
    fun reset() { now = 0; sequence = 0; queue.clear() }
    fun post(run: Runnable, delay: Long) { queue.add(Entry(now + delay, sequence++, run)) }
    fun remove(run: Runnable) { queue.removeAll { it.run === run } }
    fun advance(ms: Long) {
        val end = now + ms
        var steps = 0
        while (true) {
            val next = queue.filter { it.at <= end }.minWithOrNull(compareBy<Entry> { it.at }.thenBy { it.seq }) ?: break
            check(++steps < 10000) { "Unbounded immediate callback loop" }
            queue.remove(next); now = next.at; next.run.run()
        }
        now = end
    }
}
class Handler(looper: Looper) {
    fun post(run: Runnable): Boolean { Clock.post(run, 0); return true }
    fun postDelayed(run: Runnable, delay: Long): Boolean { Clock.post(run, delay); return true }
    fun removeCallbacks(run: Runnable) = Clock.remove(run)
}
''',
'Log.kt': '''package android.util
object Log { fun w(tag: String, message: String) = 0 }
''',
 'Task.java': '''package com.xiaomi.xms.wearable.tasks;
import java.util.*;
import java.util.concurrent.Executor;
import java.util.function.Consumer;
public class Task<T> {
    private boolean complete;
    private T value;
    private Exception error;
    private final List<Runnable> successes = new ArrayList<>();
    private final List<Runnable> failures = new ArrayList<>();
    public Task<T> addOnSuccessListener(Executor executor, Consumer<? super T> action) {
        Runnable run = () -> executor.execute(() -> action.accept(value));
        successes.add(run); if (complete && error == null) run.run(); return this;
    }
    public Task<T> addOnFailureListener(Executor executor, Consumer<Exception> action) {
        Runnable run = () -> executor.execute(() -> action.accept(error));
        failures.add(run); if (error != null) run.run(); return this;
    }
    public Task<T> resolve(T result) {
        if (complete) throw new IllegalStateException(); complete = true; value = result;
        successes.forEach(Runnable::run); return this;
    }
    public Task<T> reject() {
        if (complete) throw new IllegalStateException(); complete = true; error = new IllegalStateException("fake failure");
        failures.forEach(Runnable::run); return this;
    }
}
''',
'NodeApi.java': '''package com.xiaomi.xms.wearable;
import java.util.*;
import com.xiaomi.xms.wearable.node.*;
import com.xiaomi.xms.wearable.tasks.Task;
public class NodeApi {
    public List<Node> connected = new ArrayList<>(List.of(new Node("band")));
    public boolean installed = true;
    public List<String> subscriptions = new ArrayList<>();
    public OnDataChangedListener listener;
    public Task<List<Node>> getConnectedNodes() { return new Task<List<Node>>().resolve(connected); }
    public Task<Boolean> isWearAppInstalled(String node) { return new Task<Boolean>().resolve(installed); }
    public Task<Void> subscribe(String node, DataItem item, OnDataChangedListener value) { subscriptions.add(node); listener = value; return new Task<Void>().resolve(null); }
    public Task<Void> unsubscribe(String node, DataItem item) { listener = null; return new Task<Void>().resolve(null); }
    public Task<Void> launchWearApp(String node, String uri) { return new Task<Void>().resolve(null); }
    public void disconnect(String node) { connected = connected.stream().filter(n -> !n.getId().equals(node)).toList(); if (listener != null) listener.changed(node, DataItem.ITEM_CONNECTION, new DataSubscribeResult(2)); }
}
''',
'MessageApi.java': '''package com.xiaomi.xms.wearable;
import java.util.*;
import java.nio.charset.StandardCharsets;
import com.xiaomi.xms.wearable.message.OnMessageReceivedListener;
import com.xiaomi.xms.wearable.tasks.Task;
public class MessageApi {
    public List<String> registrations = new ArrayList<>();
    public List<String> sent = new ArrayList<>();
    public boolean failSend;
    public OnMessageReceivedListener listener;
    public Task<Void> addListener(String node, OnMessageReceivedListener value) { registrations.add(node); listener = value; return new Task<Void>().resolve(null); }
    public Task<Void> removeListener(String node) { listener = null; return new Task<Void>().resolve(null); }
    public Task<Void> sendMessage(String node, byte[] bytes) { sent.add(new String(bytes, StandardCharsets.UTF_8)); return failSend ? new Task<Void>().reject() : new Task<Void>().resolve(null); }
}
''',
'Permission.kt': '''package com.xiaomi.xms.wearable.auth
enum class Permission { DEVICE_MANAGER }
''',
'Message.kt': '''package com.xiaomi.xms.wearable.message
fun interface OnMessageReceivedListener { fun received(source: String, bytes: ByteArray) }
''',
'Node.kt': '''package com.xiaomi.xms.wearable.node
enum class DataItem(val type: Int) { ITEM_CONNECTION(1) }
class DataSubscribeResult(val connectedStatus: Int) { companion object { const val RESULT_CONNECTION_CONNECTED = 1 } }
fun interface OnDataChangedListener { fun changed(source: String, item: DataItem, change: DataSubscribeResult) }
data class Node(val id: String)
''',
'Service.kt': '''package com.xiaomi.xms.wearable.service
interface OnServiceConnectionListener { fun onServiceConnected(); fun onServiceDisconnected() }
''',
'Wearable.kt': '''package com.xiaomi.xms.wearable
import android.content.Context
import android.os.Clock
import com.xiaomi.xms.wearable.auth.Permission
import com.xiaomi.xms.wearable.message.OnMessageReceivedListener
import com.xiaomi.xms.wearable.node.*
import com.xiaomi.xms.wearable.service.OnServiceConnectionListener
import com.xiaomi.xms.wearable.tasks.*
object Wearable {
    var node = NodeApi(); var auth = AuthApi(); var message = MessageApi(); var service = ServiceApi()
    fun reset() { node = NodeApi(); auth = AuthApi(); message = MessageApi(); service = ServiceApi() }
    fun getNodeApi(context: Context) = node
    fun getAuthApi(context: Context) = auth
    fun getMessageApi(context: Context) = message
    fun getServiceApi(context: Context) = service
}
class ServiceApi {
    var listener: OnServiceConnectionListener? = null
    var online = true
    var deferred: Task<Int>? = null
    val reads = mutableListOf<Long>()
    fun registerServiceConnectionListener(value: OnServiceConnectionListener) { listener = value }
    fun unregisterServiceConnectionListener(value: OnServiceConnectionListener) { check(listener === value); listener = null }
    fun getServiceApiLevel(): Task<Int> { reads.add(Clock.now); deferred?.let { deferred = null; return it }; return if (online) Task<Int>().resolve(1) else Task<Int>().reject() }
    fun disconnect() { online = false; listener?.onServiceDisconnected() }
    fun connect() { online = true; listener?.onServiceConnected() }
}
class AuthApi {
    var granted = true
    var prompts = 0
    fun checkPermission(node: String, permission: Permission) = Task<Boolean>().resolve(granted)
    fun requestPermission(node: String, permission: Permission): Task<List<Permission>> { prompts++; return Task<List<Permission>>().resolve(if (granted) listOf(permission) else emptyList()) }
}
'''
}
with tempfile.TemporaryDirectory(prefix='orialis-wear-native-') as folder:
    root = Path(folder)
    for name, content in stubs.items():
        (root / name).write_text(content)
    bridge = (main / 'WearBridge.kt').read_text()
    types = bridge[bridge.index('enum class WearAvailability'):bridge.index('class SdkUnavailableWearAdapter')]
    (root / 'WearTypes.kt').write_text('package top.jxcz.orialis\n' + types)
    sources = [str(path) for path in root.glob('*.kt')] + [str(path) for path in root.glob('*.java')] + [str(main / 'XiaomiWearAdapter.kt'), str(here / 'WearReconnectCheck.kt')]
    output = root / 'classes'
    subprocess.run([str(java), '-cp', os.pathsep.join(compiler), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-nowarn', '-classpath', compiler[1], '-d', str(output), *sources], check=True)
    subprocess.run([str(java.with_name('javac')), '-cp', os.pathsep.join([str(output), compiler[1]]), '-d', str(output), *[str(path) for path in root.glob('*.java')]], check=True)
    subprocess.run([str(java), '-cp', os.pathsep.join([str(output), compiler[1]]), 'top.jxcz.orialis.WearReconnectCheckKt'], check=True)
