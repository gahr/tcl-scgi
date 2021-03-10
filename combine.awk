match($0, /^@[a-z-]+.tcl@/) {
	f=substr($0, RSTART+1, RLENGTH-2);
    print("######### BEGIN " f " #########");
    if (system("cat src/" f)) {
        exit 1
    }
    print("######### END " f " #########\n");
    next;
}
{
    print
}

