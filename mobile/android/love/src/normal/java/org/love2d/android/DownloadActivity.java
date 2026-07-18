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

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.Manifest;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import androidx.core.app.ActivityCompat;

public class DownloadActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
            ActivityCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)
        {
            runDownloader();
            finish();
        } else {
            ActivityCompat.requestPermissions(this, new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE}, GameActivity.EXTERNAL_STORAGE_REQUEST_CODE);
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);

        if (grantResults.length > 0) {
            Log.d("DownloadActivity", "Received a request permission result");

            if (requestCode == GameActivity.EXTERNAL_STORAGE_REQUEST_CODE) {
                if (grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    runDownloader();
                    finish();
                } else {
                    Log.d("DownloadActivity", "Did not get permission.");
                    if (ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.WRITE_EXTERNAL_STORAGE)) {
                        showExternalStoragePermissionMissingDialog();
                    }
                }
            }
            else {
                super.onRequestPermissionsResult(requestCode, permissions, grantResults);
            }
        }
    }

    protected void showExternalStoragePermissionMissingDialog() {
        AlertDialog dialog = new AlertDialog.Builder(this)
            .setTitle("Storage Permission Missing")
            .setMessage("LÖVE for Android will not be able to download games without storage permission.")
            .setNeutralButton("Continue", new DialogInterface.OnClickListener() {
                public void onClick(DialogInterface dialog, int whichButton) {
                    dialog.dismiss();
                    finish();
                }
            })
            .create();
        dialog.show();
    }

    protected void runDownloader()
    {
        Intent intent = getIntent();
        
        if (intent != null) {
            Uri uri = intent.getData();
            Intent targetIntent = new Intent(this, DownloadService.class);
            targetIntent.putExtra("url", uri.toString());
            startService(targetIntent);
        }
    }
}
