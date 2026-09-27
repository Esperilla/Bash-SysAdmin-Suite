#!/bin/bash
#==================================#
# SYSTEM MESSAGE SCRIPT            #
#==================================#
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

success_message() {
    echo -e "${GREEN}✓ $1${NC}"
}

info_message() {
    echo -e "${BLUE}ℹ $1${NC}"
}

error_message() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

warning_message() {
    echo -e "${YELLOW}⚠ $1${NC}"
}