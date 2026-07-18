This folder should contain external Lua C modules that will be shipped along with LOVE. One for each folder

Each folder must contains:
* Android.mk describing how to build the external Lua C module.
  The LOCAL_MODULE_FILENAME must be set accordingly as ndk-build appends "lib" prefix from LOCAL_MODULE by default.
  For Lua includes and libraries, simply link the native library with "liblove".
  Caveat: If the library is meant to be loaded as require("my.library") then you MUST set LOCAL_MODULE_FILENAME to my.library (with dots)
  Caveat 2: Due to bug in AGP, the LOCAL_MODULE_FILENAME must match with the folder name!
* If your module interacts with Java-side, a file java.txt must contain where it should look Java source files.
  Example, if you have src/java/your/package/name/MyFile.java, then you need to write "src/java" in java.txt.
  If this file is absent, then your Java-side code will not be compiled along.
