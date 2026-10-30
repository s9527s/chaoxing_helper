# 保留 Flutter 引擎相关类
-keep class io.flutter.** { *; }

# 保留 AndroidX 注解（防止 R8 误删）
-keepattributes *Annotation*

# 保留你项目中可能用到的反射类（如果后续遇到崩溃可在此补充）