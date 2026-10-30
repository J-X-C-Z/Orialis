package top.jxcz.orialis

import android.content.Context
import android.os.Clock
import com.xiaomi.xms.wearable.Wearable
import com.xiaomi.xms.wearable.node.Node
import com.xiaomi.xms.wearable.tasks.Task

private class Fixture {
    val adapter: XiaomiWearAdapter
    var status = WearDiagnostics(WearAvailability.AVAILABLE)
    val incoming = mutableListOf<WearIncomingMessage>()
    init {
        Clock.reset()
        Wearable.reset()
        adapter = XiaomiWearAdapter(Context())
        adapter.observe({ status = it }, { incoming.add(it) })
        adapter.connect { status = it }
        Clock.advance(0)
        adapter.selectNode("band") { status = it }
        Clock.advance(0)
        check(status.session != null)
    }
}

fun main() {
    fun test(name: String, action: () -> Unit) { action(); println("PASS $name") }

    test("service recovery creates a fresh session on the original band") {
        val f = Fixture()
        val oldSession = f.status.session
        val oldListener = Wearable.message.listener!!
        Wearable.service.disconnect()
        check(f.status.session == null)
        Clock.advance(999)
        check(Wearable.service.reads.size == 1)
        Wearable.service.connect()
        Clock.advance(0)
        check(f.status.observedNodeId == "band")
        check(f.status.session != null && f.status.session != oldSession)
        check(Wearable.message.registrations == listOf("band", "band"))
        oldListener.received("band", "old".toByteArray())
        check(f.incoming.isEmpty())
        Wearable.message.listener!!.received("band", "new".toByteArray())
        check(f.incoming.single().data == "new")
        check(Wearable.message.sent.isEmpty())
        f.adapter.dispose()
    }

    test("unavailable service retries with increasing gaps and stops on disconnect") {
        val f = Fixture()
        Wearable.service.disconnect()
        Clock.advance(4500)
        check(Wearable.service.reads == listOf(0L, 1000L, 1500L, 2000L, 2500L, 4500L)) { Wearable.service.reads.toString() }
        Clock.advance(1500)
        val count = Wearable.service.reads.size
        Clock.advance(3999)
        check(Wearable.service.reads.size == count)
        Clock.advance(1)
        check(Wearable.service.reads.size == count + 1)
        f.adapter.disconnect { check(it == null) }
        val stoppedCount = Wearable.service.reads.size
        Wearable.service.connect()
        Clock.advance(120000)
        check(Wearable.service.reads.size == stoppedCount)
        check(f.status.session == null && f.status.observedNodeId == null)
        f.adapter.dispose()
    }

    test("a different available band is never silently selected") {
        val f = Fixture()
        Wearable.node.disconnect("band")
        Wearable.node.connected = listOf(Node("another"))
        Clock.advance(1000)
        check(f.status.session == null)
        check(f.status.observedNodeId == "band")
        check(Wearable.message.registrations == listOf("band"))
        Wearable.node.connected = listOf(Node("another"), Node("band"))
        Clock.advance(2000)
        check(f.status.session != null && f.status.observedNodeId == "band")
        check(Wearable.message.registrations == listOf("band", "band"))
        f.adapter.dispose()
    }

    test("late discovery result cannot restore a disconnected adapter") {
        val f = Fixture()
        val delayed = Task<Int>()
        Wearable.service.deferred = delayed
        f.adapter.refresh { }
        f.adapter.disconnect { }
        val count = Wearable.message.registrations.size
        delayed.resolve(1)
        Clock.advance(120000)
        check(f.status.session == null)
        check(Wearable.message.registrations.size == count)
        f.adapter.dispose()
    }

    test("send failure reconnects without replaying the failed message") {
        val f = Fixture()
        val oldSession = f.status.session!!
        Wearable.message.failSend = true
        var failure: WearFailure? = null
        f.adapter.send("band", oldSession, "one-shot") { failure = it }
        Clock.advance(0)
        check(failure != null && f.status.session == null)
        Wearable.message.failSend = false
        Clock.advance(1000)
        check(f.status.session != null && f.status.session != oldSession)
        check(Wearable.message.sent == listOf("one-shot"))
        f.adapter.dispose()
    }

    test("permission denial stops automatic retries without showing a prompt") {
        val f = Fixture()
        Wearable.auth.granted = false
        Wearable.node.disconnect("band")
        Wearable.node.connected = listOf(Node("band"))
        Clock.advance(1000)
        check(f.status.lastError == "permission_required")
        val reads = Wearable.service.reads.size
        Clock.advance(120000)
        check(Wearable.service.reads.size == reads)
        check(Wearable.auth.prompts == 0)
        f.adapter.dispose()
    }

    test("dispose cancels retry and unregisters service callbacks") {
        val f = Fixture()
        Wearable.service.disconnect()
        f.adapter.dispose()
        val reads = Wearable.service.reads.size
        check(Wearable.service.listener == null)
        Clock.advance(120000)
        check(Wearable.service.reads.size == reads)
    }

    println("7 native reconnect behavior checks passed")
}
