package cc.hafa.drift

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // the bar icons follow the system's light or dark mode, not the platform theme's
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            DriftTheme {
                DriftApp(viewModel())
            }
        }
    }
}
