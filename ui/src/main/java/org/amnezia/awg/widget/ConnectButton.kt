/*
 * athena/LOS23.2: круглая кнопка подключения.
 *
 * Геометрия и цвета сняты из ConnectButton.qml клиента AmneziaVPN, чтобы наш
 * ядерный туннель выглядел как штатное приложение: круг 190dp, кольцо 3dp при
 * радиусе 93, свечение радиусом 10, надпись весом 700 размером 20 по центру,
 * а во время подключения поверх тусклого кольца крутится дуга в 180 градусов
 * с оборотом за секунду.
 */
package org.amnezia.awg.widget

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Looper
import android.util.AttributeSet
import android.util.TypedValue
import androidx.core.content.ContextCompat
import android.view.View
import android.view.animation.LinearInterpolator
import org.amnezia.awg.R

class ConnectButton @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    enum class State { DISCONNECTED, CONNECTING, DISCONNECTING, CONNECTED }

    private val density = resources.displayMetrics.density
    private val scaledDensity = resources.displayMetrics.scaledDensity

    /** Кольцо и надпись в покое. */
    private val paleGray = Color.parseColor("#D7D8DB")
    /** Подключено: кольцо, надпись и свечение. */
    private val goldenApricot = Color.parseColor("#FBB26A")
    /** Тусклое кольцо, по которому едет дуга во время подключения. */
    private val darkCharcoal = Color.parseColor("#261E1A")

    /**
     * Нейтральный цвет кольца и надписи, пока туннель не поднят.
     *
     * У AmneziaVPN это #D7D8DB, но там экран всегда тёмный. Наше приложение
     * следует системной теме, и на светлой такой серый почти не виден, поэтому
     * берём цвет основного текста темы, а к палитре Amnezia возвращаемся, если
     * тема его не отдала.
     */
    private val neutral: Int = run {
        val tv = TypedValue()
        if (context.theme.resolveAttribute(android.R.attr.textColorPrimary, tv, true) && tv.resourceId != 0)
            ContextCompat.getColorStateList(context, tv.resourceId)?.defaultColor ?: paleGray
        else paleGray
    }

    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 3f * density
        strokeCap = Paint.Cap.ROUND
    }
    private val arcPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 3f * density
        strokeCap = Paint.Cap.ROUND
    }
    /**
     * Свечение рисуем сами -- несколькими кольцами с падающей прозрачностью.
     *
     * Paint.setShadowLayer требует LAYER_TYPE_SOFTWARE, а тот на светлой теме
     * оставлял вокруг кнопки серый квадрат по границам View (виден на снимке
     * с устройства 2026-09-09). Ручные кольца работают на аппаратном слое и
     * ничего лишнего не рисуют.
     */
    private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
    }

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        textSize = 20f * scaledDensity
        typeface = android.graphics.Typeface.create(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD)
    }

    private val oval = RectF()

    /** Крутится только во время подключения, иначе аниматор остановлен. */
    private var sweepStart = 0f
    private val spinner = ValueAnimator.ofFloat(0f, 360f).apply {
        duration = 1000L
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener {
            sweepStart = it.animatedValue as Float
            invalidate()
        }
    }

    var state: State = State.DISCONNECTED
        set(value) {
            if (field == value) return
            field = value
            // Состояние приходит и с фоновых потоков: ObservableTunnel шлёт
            // уведомление из того потока, где отработала операция с туннелем.
            // ValueAnimator этого не прощает -- "Animators may only be run on
            // Looper threads", и исключение всплывало наверх как «ошибка при
            // подъёме туннеля», хотя туннель переключался нормально
            // (замер 10:32:22 на 5000014556). invalidate() из чужого потока
            // тоже нельзя.
            if (Looper.myLooper() == Looper.getMainLooper()) applyState() else post { applyState() }
        }

    private fun applyState() {
        if (state == State.CONNECTING || state == State.DISCONNECTING) {
            if (!spinner.isStarted) spinner.start()
        } else {
            spinner.cancel()
        }
        invalidate()
    }

    init {
        isClickable = true
        isFocusable = true
    }

    /** Мягкое свечение: три кольца шире основного, прозрачность падает наружу. */
    private fun drawGlow(canvas: Canvas, cx: Float, cy: Float, radius: Float, color: Int, peakAlpha: Int) {
        for (i in 1..3) {
            glowPaint.strokeWidth = (3f + i * 4f) * density
            glowPaint.color = ((peakAlpha / (i * i)) shl 24) or (color and 0xFFFFFF)
            canvas.drawCircle(cx, cy, radius, glowPaint)
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = (190f * density).toInt()
        setMeasuredDimension(
            resolveSize(size, widthMeasureSpec),
            resolveSize(size, heightMeasureSpec)
        )
    }

    override fun onDetachedFromWindow() {
        spinner.cancel()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        // Радиус 93 при габарите 190, как в оригинале.
        val radius = (93f / 190f) * minOf(width, height)
        oval.set(cx - radius, cy - radius, cx + radius, cy + radius)

        when (state) {
            State.CONNECTED -> {
                drawGlow(canvas, cx, cy, radius, goldenApricot, 0x88)
                ringPaint.color = goldenApricot
                textPaint.color = goldenApricot
            }
            State.CONNECTING, State.DISCONNECTING -> {
                ringPaint.color = (0x33 shl 24) or (neutral and 0xFFFFFF)
                textPaint.color = neutral
            }
            State.DISCONNECTED -> {
                // То же свечение, но приглушённое: в покое ему незачем спорить с кольцом.
                drawGlow(canvas, cx, cy, radius, goldenApricot, 0x28)
                ringPaint.color = neutral
                textPaint.color = neutral
            }
        }
        canvas.drawCircle(cx, cy, radius, ringPaint)

        if (state == State.CONNECTING || state == State.DISCONNECTING) {
            arcPaint.color = neutral
            canvas.drawArc(oval, sweepStart - 115f, 180f, false, arcPaint)
        }

        val label = when (state) {
            State.CONNECTED -> context.getString(R.string.tunnel_status_connected)
            State.CONNECTING -> context.getString(R.string.tunnel_status_connecting)
            State.DISCONNECTING -> context.getString(R.string.connect_button_disconnecting)
            State.DISCONNECTED -> context.getString(R.string.connect_button_connect)
        }
        val metrics = textPaint.fontMetrics
        canvas.drawText(label, cx, cy - (metrics.ascent + metrics.descent) / 2f, textPaint)
    }
}
