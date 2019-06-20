#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <string.h>

int main(int argc, char* argv[]) {
    FILE *fp= NULL;
    pid_t pid = 0;
    pid_t sid = 0;
    pid = fork();
    if (pid < 0) {
        perror("fork");
        return EXIT_FAILURE;
    }

    if (pid) {
        return EXIT_SUCCESS;
    }

    umask(0);
    sid = setsid();
    if(sid < 0) {
        return EXIT_FAILURE;
    }

    chdir("/etc/rotel");
    //close(STDIN_FILENO);
    //close(STDOUT_FILENO);
    //close(STDERR_FILENO);

    return execl("/usr/bin/ruby", "rotel-server", "/etc/rotel/rotel-server.rb", "--", "-d", (char *) NULL);
}
