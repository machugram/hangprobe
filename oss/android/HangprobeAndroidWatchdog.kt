// SPDX-License-Identifier: MIT
// MIT device SDK (oss/android) — standalone watchdog, dependency-light.

package com.hangprobe.watchdog

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean

object HangprobeAndroidWatchdog {
    private val running = AtomicBoolean(false)
    private var worker: Thread? = null

    fun start(
        endpoint: String = "http://10.0.2.2:9481/v1/hangs",
        appName: String,
        packageName: String = appName,
        commit: String? = null,
        thresholdMs: Long = 250L,
        pollMs: Long = 50L,
        isDebugBuild: Boolean = true,
        screenProvider: (() -> String?)? = null,
    ) {
        if (!isDebugBuild) return
        if (!running.compareAndSet(false, true)) return

        val mainHandler = Handler(Looper.getMainLooper())
        val mainThread = Looper.getMainLooper().thread

        worker = Thread({
            while (running.get() && !Thread.currentThread().isInterrupted) {
                val answered = AtomicBoolean(false)
                val start = SystemClock.uptimeMillis()
                mainHandler.post { answered.set(true) }
                var reported = false

                while (running.get() && !answered.get()) {
                    Thread.sleep(pollMs)
                    val gap = SystemClock.uptimeMillis() - start
                    if (gap >= thresholdMs && !reported) {
                        reported = true
                        val state = mainThread.state
                        val rawTrace = mainThread.stackTrace
                        val payload = buildJson(
                            gapMs = gap,
                            thresholdMs = thresholdMs,
                            state = state,
                            trace = rawTrace,
                            appName = appName,
                            packageName = packageName,
                            commit = commit,
                            screen = screenProvider?.invoke(),
                        )
                        postJson(endpoint, payload)
                    }
                }
                Thread.sleep(pollMs)
            }
        }, "hangprobe-watchdog").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        running.set(false)
        worker?.interrupt()
        worker = null
    }

    internal fun buildJson(
        gapMs: Long,
        thresholdMs: Long,
        state: Thread.State,
        trace: Array<StackTraceElement>,
        appName: String,
        packageName: String,
        commit: String?,
        screen: String?,
    ): String {
        val leafFirst = trace.take(16).reversed()
        val frames = leafFirst.map { "at ${it.className}.${it.methodName}(${it.fileName ?: "Source"}:${it.lineNumber})" }
        val leaf = trace.firstOrNull()
        val blocked = state == Thread.State.BLOCKED || state == Thread.State.WAITING || state == Thread.State.TIMED_WAITING
        val kind = if (blocked) "blocked" else "busy"
        val isAnr = gapMs >= 5000L
        val note = if (isAnr) {
            "ANR threshold crossed (>= 5000 ms) on Looper main thread."
        } else {
            "Debug Looper watchdog (>= ${thresholdMs} ms, not a 5s ANR)."
        }

        val ctx = JSONObject().apply {
            if (commit != null) put("commit", commit)
            if (screen != null) put("screen", screen)
            put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
            put("os", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            put("arch", Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")
            put("captured_at", Instant.now().toString())
        }

        return JSONObject().apply {
            put("hung", true)
            put("kind", kind)
            put("main_gap_ms", gapMs)
            put("gap_at_least", true)
            put("busy_ms", if (kind == "busy") gapMs else 0)
            put("blocked_ms", if (kind == "blocked") gapMs else 0)
            put("event_wait_ms", 0)
            put("window_ms", gapMs)
            put("threshold_ms", thresholdMs)
            put("samples", 1)
            put("top", if (leaf != null) "${leaf.className}.${leaf.methodName}" else packageName)
            put("stack", JSONArray(frames))
            put("pid", android.os.Process.myPid())
            put("app", appName)
            put("bundle_id", packageName)
            put("where", "android")
            put("note", note)
            put("context", ctx)
        }.toString()
    }

    private fun postJson(endpoint: String, body: String) {
        runCatching {
            val conn = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 3000
                readTimeout = 3000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
            OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(body) }
            conn.responseCode
            conn.disconnect()
        }
    }
}
