export LAB_DIR=$RUNNER_TEMP/lab; mkdir -p $LAB_DIR && (cd $LAB_DIR && npm init -y >/dev/null && npm i playwright@1.49.1 @supabase/supabase-js@2.45.4 >/dev/null 2>&1 && npx playwright install --with-deps chromium >/dev/null 2>&1)
export NODE_PATH=$LAB_DIR/node_modules
cp -r $LAB_DIR/node_modules ./node_modules 2>/dev/null
DEBUG=1 WORKERS=1 ONLY_CATS=brands,clubs,athletes,fruits,cuisines,drinks,civilizations,languages node scripts/search-lab/audit.mjs
