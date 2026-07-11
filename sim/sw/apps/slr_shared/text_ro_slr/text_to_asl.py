
# execute by: python text_to_asl.py -text "let the sun shine" -show  -gmt
#---------------------------------------------------------------------------------
import zipfile
import random
import argparse
from io import BytesIO
from PIL import Image, ImageDraw, ImageFont
import cv2
import numpy as np
import torch
import os
import sys
sys.path.append('../pt')
import gen_slr_ptds as gsp

ZIP_PATH = "../pt/slr_dataset_src.zip"
BASE_PATH = "data"   # top folder inside zip

# ---------- Build index of files inside ZIP ----------

def build_index(zip_file):

    # get  fail_paths_list
    fail_paths_list = []
   
    with open('../pt/workspace/ds_fail_paths.txt', 'r') as ds_fail_paths_f :
      for line in ds_fail_paths_f :
        fail_paths_list.append(line.split()[0])
        
    index = {}

    for name in zip_file.namelist():
        # Expect: data/A/xxx.jpg
        parts = name.split("/")

        if len(parts) >= 3 and parts[0] == BASE_PATH:
            letter = parts[1]

            if letter not in index:
                index[letter] = []

            if name.lower().endswith((".jpg", ".jpeg", ".png")):
                if name not in fail_paths_list :
                   index[letter].append(name)        
    return index

# ---------- Map character ----------
def char_to_letter(c):
    if c == " ":
        return "space"  # optional, may not exist
    if c.isalpha():
        return c.lower()
    return None


# ---------- Get random image from ZIP ----------
def get_random_image(zip_file, index, letter):

    if letter not in index or not index[letter]:
        if letter!='space' :
          print(f"No images for: {letter} placing space")
        return None, None

    file_in_zip = random.choice(index[letter])
    
    with zip_file.open(file_in_zip) as f:
        img_data = f.read()

    img_path = None if letter=='space' else file_in_zip
    return Image.open(BytesIO(img_data)).convert("RGB") , img_path

# ---------- Draw label ----------

def draw_label(img, text):
    # Ensure image supports alpha
    img = img.convert("RGBA")

    # Create transparent overlay
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Load font
    try:
        font = ImageFont.truetype("arial.ttf", 20)
    except:
        font = ImageFont.load_default()

    # Measure text size
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]

    # Position (bottom-left)
    x = 5
    y = img.height - text_h - 10

    # Draw semi-transparent rectangle (alpha=120 out of 255)
    padding = 4
    rect = [
        x - padding,
        y - padding,
        x + text_w + padding,
        y + text_h + padding
    ]
    draw.rectangle(rect, fill=(0, 0, 0, 60))  # <-- transparency here

    # Draw text (fully opaque white)
    draw.text((x, y), text, fill=(255, 255, 255, 255), font=font)

    # Combine overlay with image
    combined = Image.alpha_composite(img, overlay)

    return combined.convert("RGB")  # back to RGB for saving

# ---------- Convert text ----------
def text_to_images(zip_file, index, text, size=(128, 128)):
    images = []
    img_paths = []
    labels = []

    for c in text:
        letter = char_to_letter(c)
        if not letter:
            continue

        img, img_path = get_random_image(zip_file, index, letter)
        
        if img:
            img = img.resize(size)
            label = c.lower() if c != " " else " "
            if not args.nlb:
              img = draw_label(img, label)
            images.append(img)
            img_paths.append(img_path)
            labels.append(ord(label)-ord('a'))           
        else:
            # fallback for space
            blank = Image.new("RGB", size, (0, 0, 0))
            images.append(blank) 
            img_paths.append('space')
            labels.append(ord('z')-ord('a')+1)  
 
    return images, img_paths, labels

#-------------------------------------------------------------------------

def text_to_word_images(zip_file, index, text, size=(128, 128)):
    words = text.split(" ")
    result = []

    for word in words:
        images = []
        for c in word:
            letter = char_to_letter(c)
            if not letter:
                continue

            img,img_path = get_random_image(zip_file, index, letter)
            if img:
                img = img.resize(size)
                if not args.nlb :
                   img = draw_label(img, c.upper())
                images.append(img)

        result.append(images)

    return result

#-------------------------------------------------------------------------

def stitch_words_lines(words_images, h_spacing=10, v_spacing=20):
    """
    words_images = list of lists of PIL images
    each inner list = one word
    """

    rows = []

    # Step 1: stitch each word into a row
    for images in words_images:
        if not images:
            continue

        widths, heights = zip(*(img.size for img in images))
        total_width = sum(widths) + h_spacing * (len(images) - 1)
        max_height = max(heights)

        row_img = Image.new("RGB", (total_width, max_height), (255, 255, 255))

        x = 0
        for img in images:
            row_img.paste(img, (x, 0))
            x += img.width + h_spacing

        rows.append(row_img)

    if not rows:
        return None

    # Step 2: stack rows vertically
    widths, heights = zip(*(img.size for img in rows))

    max_width = max(widths)
    total_height = sum(heights) + v_spacing * (len(rows) - 1)

    canvas = Image.new("RGB", (max_width, total_height), (255, 255, 255))

    y = 0
    for row in rows:
        canvas.paste(row, (0, y))
        y += row.height + v_spacing

    return canvas

# ---------- GIF ----------

def create_gif_sequence_v0(images, filename="output.gif", duration=500): # ALSO WORKS
    if not images:
        return

    images[0].save(
        filename,
        save_all=True,
        append_images=images[1:],
        duration=duration,
        loop=0
    )

# -------------------------------------------------------

def create_gif_sequence(words_images, filename="outputs/seq_output.gif",
                        letter_duration=300, word_pause=600):
    """
    words_images = list of lists (words -> letters)
    """

    frames = []

    for word in words_images:
        for img in word:
            frames.append(img)

        # Add pause after each word (repeat last frame)
        if word:
            for _ in range(word_pause // letter_duration):
                frames.append(word[-1])

    if not frames:
        return

    frames[0].save(
        filename,
        save_all=True,
        append_images=frames[1:],
        duration=letter_duration,
        loop=0
    )

# ---------- Main ----------
if __name__ == "__main__":


    ap = argparse.ArgumentParser(description='slr translator') 
    ap.add_argument('-text'  , metavar='<in_txt>', type=str, default=None, help='Input Text (default from prompt)' )    
    ap.add_argument('-show'  , action='store_true' , help='show the sequence') 
    ap.add_argument('-nlb'   , action='store_true' , help='don\'t add labels to displayed image')       
    ap.add_argument('-gmt'   , action='store_true' , help='generate mannix text file')    
    
    args = ap.parse_args()

    with zipfile.ZipFile(ZIP_PATH, 'r') as z:
        index = build_index(z)

        if args.text == None:
          text = input("Enter text: ")
        else :
          text = args.text

        imgs, img_paths, labels = text_to_images(z, index, text)
        
        if args.gmt :
        
             ds_arc = z
             img_size=32
             labels_dict,labels_list  = gsp.gen_labels_dict() 
             no_spaces = True # No need to add further spaces
             text_ds_tensor = gsp.create_tensor_dataset(ds_arc, img_paths, labels, img_size, labels_dict, no_spaces)
             
             torch.save(dict(
                 pt_ds=text_ds_tensor,
                 lnbi=labels_list,
                 imgp=img_paths),'outputs/slr_ds_text.pt')
                 
             os.system('cp outputs/slr_ds_text.pt ../pt/workspace/')
             os.system("%s ../pt/ds_pt_to_mnx.py -gdn slr -spl text -wsp ../pt/workspace" % sys.executable) 
             os.system('cp ../pt/workspace/slr_ds_mnx.txt  outputs/')
           
        words_imgs = text_to_word_images(z, index, text)
        
        create_gif_sequence(words_imgs)
                     
        result = stitch_words_lines(words_imgs)
        result.save("outputs/static_output.png")            
        
        if args.show and result:

            result.show()


