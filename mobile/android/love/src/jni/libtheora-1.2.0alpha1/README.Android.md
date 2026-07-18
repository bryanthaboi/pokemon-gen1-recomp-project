Building for Android should work using the ```config.h``` found in this
directory. Should you need to recreate the ```config.h``` file due to an
update of libtheora you have to do the following:

1. Create the folders ```theora```, and ```theora/build```
2. Extract the source of the theora library to ```theora/src```
3. Copy the files ```ndkenv.sh``` and ```configure_android.sh``` to ```theora/build```
4. Go to the ```theora/build``` directory and run ```configure_android.sh```

You might have to adjust some paths and build settings in ```ndkenv.sh```
and ```configure_android.sh```.
