Compiled for Apple Silicon M series binaries:

dumpe2fs
e2fsck
ext4fuse
mkbootimg

Random AOSP Script built while trying to build a userdebug build for BL Unlocked S25 on 15.0
File:
prepare_samfw.sh

place binaries in /project_name/compile_bin or change path in script to whatever you desire! 

If you find me, you're welcome to use me! That's why I'm public! 

NOTES:
Had to create my own script because was having A TON of trouble after using lpunpack method.
It seems the super.img was unpacking corrupted EXT type Filesysystems, and with the help of some 
AI magic, this trims the images if it finds any EXT type filesystems in the extracted image


