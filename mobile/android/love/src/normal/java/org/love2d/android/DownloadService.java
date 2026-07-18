/**
 * Copyright (c) 2006-2023 LOVE Development Team
 *
 * This software is provided 'as-is', without any express or implied
 * warranty.  In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 **/

package org.love2d.android;

import java.util.List;

import android.app.DownloadManager;
import android.app.IntentService;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.util.Log;

public class DownloadService extends IntentService {
    public DownloadService() {
        super("DownloadService");
    }

    @Override
    public void onDestroy() {
        Log.d("DownloadService", "destroying");
        unregisterReceiver(downloadReceiver);
    }

    @Override
    protected void onHandleIntent(Intent intent) {
        Log.d("DownloadService", "service started");

        String url = intent.getStringExtra("url");
        Uri uri = Uri.parse(url);

        Log.d("DownloadService", "Downloading from url: " + url + " file = " + uri.getLastPathSegment());

        DownloadManager.Request request = new DownloadManager.Request(uri);
        request.setDescription("LÖVE Game Download");
        request.setTitle(uri.getLastPathSegment());
        request.setMimeType("application/x-love-game");

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            request.allowScanningByMediaScanner();
        }

        request.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
        request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, uri.getLastPathSegment());

        // get download service and enqueue file
        Log.d("DownloadActivity", "creating manager");
        DownloadManager manager = (DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE);
        Log.d("DownloadActivity", "enqueuing download");
        manager.enqueue(request);

        Log.d("DownloadActivity", "download receiver = " + downloadReceiver);
        IntentFilter intentFilter = new IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE);
        registerReceiver(downloadReceiver, intentFilter);
    }

    private BroadcastReceiver downloadReceiver = new BroadcastReceiver() {

        @Override
        public void onReceive(Context context, Intent intent) {
            Log.d("DownloadActivity", "downloadReceiver intent called");

        }
    };
}
