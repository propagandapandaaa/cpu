# Use a base image with your preferred Linux distribution
FROM ubuntu:20.04

# Set the maintainer label
LABEL maintainer="your-email@example.com"

# Install required packages
RUN apt-get update
RUN apt-get install -y \
    ghdl \
    yosys

# Set the working directory
WORKDIR /workspace

# Optionally, copy VHDL project files into the container
COPY . /workspace

# Specify the command to run when the container starts
CMD ["bash"]
