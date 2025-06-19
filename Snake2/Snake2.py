import pygame
import sys
import random
import os

# Initialize Pygame and its mixer
pygame.init()
pygame.mixer.init()

# Constants
WIDTH = 800
HEIGHT = 600
GRID_SIZE = 20
GRID_WIDTH = WIDTH // GRID_SIZE
GRID_HEIGHT = HEIGHT // GRID_SIZE
FPS = 10

# Colors
WHITE = (255, 255, 255)
GREEN = (0, 255, 0)
RED = (255, 0, 0)
BLACK = (0, 0, 0)

# Sound setup
SOUND_DIR = os.path.join(os.path.dirname(__file__), 'sounds')
# Create sounds directory if it doesn't exist
os.makedirs(SOUND_DIR, exist_ok=True)

# Sound file paths
EAT_SOUND_PATH = os.path.join(SOUND_DIR, 'fart.wav')
CRASH_SOUND_PATH = os.path.join(SOUND_DIR, 'crash.wav')
GAME_OVER_SOUND_PATH = os.path.join(SOUND_DIR, 'game_over.wav')
FART_SOUND_PATH = os.path.join(SOUND_DIR, 'fart.wav')
EXPLOSION_SOUND_PATH = os.path.join(SOUND_DIR, 'explosion.wav')
# Initialize sounds (will be loaded once sound files are added)
eat_sound = pygame.mixer.Sound(EAT_SOUND_PATH) if os.path.exists(EAT_SOUND_PATH) else None
crash_sound = pygame.mixer.Sound(CRASH_SOUND_PATH) if os.path.exists(CRASH_SOUND_PATH) else None
game_over_sound = pygame.mixer.Sound(GAME_OVER_SOUND_PATH) if os.path.exists(GAME_OVER_SOUND_PATH) else None
explosion_sound = pygame.mixer.Sound(EXPLOSION_SOUND_PATH) if os.path.exists(EXPLOSION_SOUND_PATH) else None

# Initialize the screen
screen = pygame.display.set_mode((WIDTH, HEIGHT))
pygame.display.set_caption("Snake Game")
clock = pygame.time.Clock()

class Snake:
    def __init__(self):
        self.reset()
    
    def reset(self):
        self.length = 3
        self.positions = [(GRID_WIDTH // 4 * GRID_SIZE, GRID_HEIGHT // 2 * GRID_SIZE)]
        self.direction = "RIGHT"
        self.score = 0
        
        # Add initial tail segments
        for i in range(self.length - 1):
            self.positions.append((
                self.positions[-1][0] - GRID_SIZE,
                self.positions[-1][1]
            ))

    def update(self):
        current = self.positions[0]
        x, y = current
        
        if self.direction == "UP":
            y -= GRID_SIZE
        elif self.direction == "DOWN":
            y += GRID_SIZE
        elif self.direction == "LEFT":
            x -= GRID_SIZE
        elif self.direction == "RIGHT":
            x += GRID_SIZE
            
        self.positions.insert(0, (x, y))
        
        if len(self.positions) > self.length:
            self.positions.pop()
    
    def draw(self):
        for position in self.positions:
            pygame.draw.rect(screen, GREEN, 
                           pygame.Rect(position[0], position[1], GRID_SIZE-2, GRID_SIZE-2))

    def check_collision(self):
        head = self.positions[0]
        # Check wall collision
        if (head[0] < 0 or head[0] >= WIDTH or 
            head[1] < 0 or head[1] >= HEIGHT):
            if crash_sound:
                crash_sound.play()
            return True
        # Check self collision
        if head in self.positions[1:]:
            if crash_sound:
                crash_sound.play()
            return True
        return False

class Food:
    def __init__(self):
        self.position = self.generate_position()
        
    def generate_position(self):
        x = random.randint(0, GRID_WIDTH-1) * GRID_SIZE
        y = random.randint(0, GRID_HEIGHT-1) * GRID_SIZE
        return (x, y)
    
    def draw(self):
        pygame.draw.rect(screen, RED, 
                        pygame.Rect(self.position[0], self.position[1], GRID_SIZE-2, GRID_SIZE-2))

def show_score(score):
    font = pygame.font.Font(None, 36)
    score_text = font.render(f'Score: {score}', True, WHITE)
    screen.blit(score_text, (10, 10))

def show_game_over(score):
    font = pygame.font.Font(None, 48)
    game_over_text = font.render('Game Over!', True, WHITE)
    score_text = font.render(f'Final Score: {score}', True, WHITE)
    restart_text = font.render('Press SPACE to restart', True, WHITE)
    
    screen.blit(game_over_text, 
                (WIDTH//2 - game_over_text.get_width()//2, 
                 HEIGHT//2 - 60))
    screen.blit(score_text, 
                (WIDTH//2 - score_text.get_width()//2, 
                 HEIGHT//2))
    screen.blit(restart_text,
                (WIDTH//2 - restart_text.get_width()//2, 
                 HEIGHT//2 + 60))

def main():
    # Main game loop
    game_over = False
    snake = Snake()
    food = Food()
    clock = pygame.time.Clock()
    
    while True:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                pygame.quit()
                sys.exit()
            
            if event.type == pygame.KEYDOWN:
                if not game_over:
                    if event.key == pygame.K_UP and snake.direction != "DOWN":
                        snake.direction = "UP"
                    elif event.key == pygame.K_DOWN and snake.direction != "UP":
                        snake.direction = "DOWN"
                    elif event.key == pygame.K_LEFT and snake.direction != "RIGHT":
                        snake.direction = "LEFT"
                    elif event.key == pygame.K_RIGHT and snake.direction != "LEFT":
                        snake.direction = "RIGHT"
                elif event.key == pygame.K_SPACE:
                    snake.reset()
                    food = Food()
                    game_over = False

        if not game_over:
            snake.update()
            
            # Check if snake ate food
            if snake.positions[0] == food.position:
                if eat_sound:
                    eat_sound.play()
                snake.length += 1
                snake.score += 10
                food = Food()
            
            # Check for collisions
            if snake.check_collision():
                if game_over_sound:
                    game_over_sound.play()
                game_over = True
            
            # Check for collision with screen boundaries
            head_x, head_y = snake.positions[0]
            if head_x < 0 or head_x >= WIDTH or head_y < 0 or head_y >= HEIGHT:
                if explosion_sound:
                    explosion_sound.play()
                game_over = True

        # Drawing
        screen.fill(BLACK)
        snake.draw()
        food.draw()
        show_score(snake.score)

        if game_over:
            show_game_over(snake.score)

        pygame.display.flip()
        clock.tick(FPS)

if __name__ == "__main__":
    main()