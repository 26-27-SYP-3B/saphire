package at.htlleonding.saphire_client

import com.ryanheise.audioservice.AudioServiceActivity

// AudioServiceActivity instead of FlutterActivity, so a tap on the media notification comes back to
// this app's engine instead of starting a second one.
class MainActivity : AudioServiceActivity()
