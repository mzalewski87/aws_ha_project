# optional/dc-promote — folded into modules/spoke2_dc

AD DS forest promotion is performed inline by `modules/spoke2_dc` via user-data
PowerShell (`Install-ADDSForest`), toggled by `dc_promote_to_dc`. A standalone
post-promote workspace is not required. This directory is kept as a pointer;
add SSM RunCommand-based day-2 domain tasks here if needed later.
