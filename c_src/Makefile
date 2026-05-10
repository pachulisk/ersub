CC ?= cc
CFLAGS = -O2 -Wall -I clips_lib
LDFLAGS = -L clips_lib -lclips -lm
TARGET = ../priv/ersub_clips

.PHONY: all clean

all: $(TARGET)

$(TARGET): ersub_clips.c clips_lib/libclips.a
	@mkdir -p ../priv
	$(CC) $(CFLAGS) -o $(TARGET) ersub_clips.c $(LDFLAGS)
	@echo "Built $(TARGET)"

clean:
	rm -f $(TARGET)
